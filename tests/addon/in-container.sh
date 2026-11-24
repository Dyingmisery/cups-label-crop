#!/bin/bash
# shellcheck disable=SC2086,SC2012  # EXTRA_FLAGS/SETUP_PKGS are intentionally word-split
# Safety tests for addon/install.sh. Runs INSIDE a disposable container that
# has (or gets) a CUPS server with pre-existing queues. Never run on a real
# server: it creates and deletes test queues.
#   SETUP_PKGS="cups python3-pikepdf"  packages to apt-get install first (optional)
#   EXTRA_FLAGS="--install-deps"       extra installer flags for the install phases
# shellcheck disable=SC2015
set -uo pipefail
SRC=${SRC:-/src}
INSTALLER="$SRC/addon/install.sh"
EXTRA_FLAGS=${EXTRA_FLAGS:-}
PASS=0; FAIL=0
ok()  { echo "ok   $*"; PASS=$((PASS + 1)); }
bad() { echo "FAIL $*"; FAIL=$((FAIL + 1)); }
T=/tmp/addon-test; rm -rf "$T"; mkdir -p "$T"

# ------------------------------------------------------------- setup a "pre-existing" CUPS
if [ -n "${SETUP_PKGS:-}" ]; then
    export DEBIAN_FRONTEND=noninteractive
    if command -v apt-get >/dev/null; then
        apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends $SETUP_PKGS >/dev/null 2>&1 \
            || { echo "setup: apt-get install $SETUP_PKGS failed"; exit 3; }
    else
        dnf install -y -q --setopt=install_weak_deps=False --disablerepo="*openh264*" $SETUP_PKGS >/dev/null 2>&1 || { echo "setup: dnf install $SETUP_PKGS failed"; exit 3; }
    fi
fi
command -v lpstat >/dev/null || { echo "setup: no CUPS client"; exit 3; }
if ! lpstat -r 2>/dev/null | grep -q "is running"; then
    mkdir -p /run/cups; (cupsd >/dev/null 2>&1 &)
    for _ in $(seq 1 40); do lpstat -r 2>/dev/null | grep -q "is running" && break; sleep 0.5; done
fi
lpstat -r | grep -q "is running" || { echo "setup: cupsd not running"; exit 3; }
SB=""
for c in /usr/lib/cups /usr/libexec/cups; do [ -d "$c/backend" ] && SB=$c && break; done
echo "setup: $(. /etc/os-release; echo "$PRETTY_NAME") $(uname -m), CUPS $(lpstat -r >/dev/null; cups-config --version 2>/dev/null || dpkg-query -W -f '${Version}' cups 2>/dev/null || rpm -q cups 2>/dev/null || echo '?'), ServerBin $SB"
# Deterministic config writes for file comparisons (test setup only)
cupsctl DirtyCleanInterval=0 >/dev/null 2>&1 || true
for _ in $(seq 1 40); do lpstat -r 2>/dev/null | grep -q "is running" && break; sleep 0.5; done
cupsctl --no-share-printers >/dev/null 2>&1 || true
for _ in $(seq 1 40); do lpstat -r 2>/dev/null | grep -q "is running" && break; sleep 0.5; done

# A third-party backend that already exists on this server
cat > "$SB/backend/capture" <<'BE'
#!/bin/sh
[ $# -eq 0 ] && { echo 'direct capture "Unknown" "test capture"'; exit 0; }
d=/tmp/capture; n=$(echo "${DEVICE_URI#capture:}" | tr -dc 'a-zA-Z0-9')
if [ -n "${6:-}" ]; then cat "$6"; else cat; fi > "$d/$n-$1.pdf"
BE
chmod 755 "$SB/backend/capture"; mkdir -p /tmp/capture; chmod 1777 /tmp/capture
GPPD=$(lpinfo -m 2>/dev/null | awk '/generpcl|Generic PCL/ {print $1; exit}')
[ -n "$GPPD" ] || GPPD=raw
lpadmin -p Office_Laser -v capture:/office -m "$GPPD" -D "Office Laser" -L "Study" -o printer-is-shared=false -E 2>/dev/null
lpadmin -p Label_Printer -v capture:/label -m raw -D "Label Printer" -o printer-is-shared=true -E 2>/dev/null
lpadmin -p Kitchen_Raw -v capture:/kitchen -m raw -o printer-is-shared=false -o job-sheets-default=none,none 2>/dev/null
cupsdisable Kitchen_Raw 2>/dev/null || true
lpadmin -d Office_Laser
lpoptions -p Office_Laser -o PageSize=A4 -o sides=two-sided-long-edge >/dev/null 2>&1 || true
lpadmin -p Office_Laser -o media-default=iso_a4_210x297mm >/dev/null 2>&1 || true
lpoptions -p Label_Printer -o fit-to-page=false >/dev/null 2>&1 || true
sleep 1
echo "setup: queues: $(lpstat -v | sed 's/device for //' | tr '\n' ' ')"

# ------------------------------------------------------------- helpers
DIRS=(/etc/cups "$SB" /etc/cups-label-crop /opt/cups-label-crop /var/lib/cups-label-crop)
sums() {  # exact: every file, with mode and owner
    find "${DIRS[@]}" \( -type f -o -type l \) 2>/dev/null | sort | while read -r f; do
        printf '%s %s %s\n' "$(stat -c '%a %U:%G' "$f")" "$(sha256sum < "$f" | cut -c1-64)" "$f"
    done
}
keepconf() { mkdir -p "$T/conf-$1"; cp -p /etc/cups/printers.conf /etc/cups/cupsd.conf /etc/cups/classes.conf "$T/conf-$1/" 2>/dev/null; }
normsums() {  # ignores cupsd's own volatile bits: *.O backups, timestamps in printers.conf, ssl/
    find /etc/cups "$SB" \( -type f -o -type l \) 2>/dev/null | grep -vE '\.O$|/ssl/' | sort | while read -r f; do
        case "$f" in
            */printers.conf|*/classes.conf|*/subscriptions.conf)
                h=$(grep -vE '^(# Written by cupsd|StateTime|ConfigTime|Attribute marker-change-time|StateMessage|Reason|NextSubscriptionId|NextJobId|NextPrinterId)' "$f" | sha256sum | cut -c1-64) ;;
            *) h=$(sha256sum < "$f" | cut -c1-64) ;;
        esac
        printf '%s %s %s\n' "$(stat -c '%a %U:%G' "$f")" "$h" "$f"
    done
}
queues_state() {  # independent of the installer's own snapshot code
    lpstat -d 2>/dev/null; cupsctl 2>/dev/null | grep -E '^_(share|remote)'
    for q in $(lpstat -v 2>/dev/null | sed -n 's/^device for \([^:]*\):.*/\1/p' | grep -v '^Label_Crop$' | grep -v '^Vinted_Label$' | sort); do
        echo "== $q $(lpstat -v "$q")"
        lpstat -l -p "$q" | grep -E 'Description|Location|Interface|enabled|disabled' | sed 's/since.*//'
        [ -f "/etc/cups/ppd/$q.ppd" ] && sha256sum < "/etc/cups/ppd/$q.ppd"
        lpoptions -p "$q" -l 2>/dev/null
        lpoptions -p "$q" 2>/dev/null | tr ' ' '\n' | grep -vE '^(printer-state|marker-|printer-state-change-time|printer-state-reasons|printer-type|printer-commands|printer-up-time)'
    done
}
run() { local name=$1; shift; bash "$INSTALLER" "$@" > "$T/$name.log" 2>&1; echo $?; }
same() { local d; d="$T/$(echo "$3" | tr -c 'a-zA-Z0-9\n' '_').diff"
    if diff -u "$1" "$2" > "$d"; then ok "$3"; else bad "$3"; sed 's/^/      /' "$d" | head -40; fi; }

# ------------------------------------------------------------- 1. dry run changes nothing
sums > "$T/s0"; queues_state > "$T/q0"
rc=$(run dry --dry-run --target Label_Printer $EXTRA_FLAGS)
[ "$rc" = 0 ] && ok "dry-run exits 0" || { bad "dry-run rc=$rc"; tail -20 "$T/dry.log"; }
grep -q "Dry run: nothing was changed" "$T/dry.log" && ok "dry-run prints its plan" || bad "dry-run output"
sums > "$T/s1"; same "$T/s0" "$T/s1" "dry-run: /etc/cups, ServerBin and add-on paths byte-identical"
[ ! -e /var/backups/cups-label-crop ] && [ ! -e /var/lib/cups-label-crop ] && [ ! -e /opt/cups-label-crop ] \
    && ok "dry-run created no backup/state/opt dirs" || bad "dry-run created dirs"

# ------------------------------------------------------------- 2. refusals change nothing
rc=$(setpriv --reuid=nobody --regid="$(id -g nobody)" --clear-groups bash "$INSTALLER" --target Label_Printer --yes > "$T/nonroot.log" 2>&1; echo $?)
[ "$rc" != 0 ] && grep -q "run as root" "$T/nonroot.log" && ok "non-root refused" || bad "non-root rc=$rc"

echo "#!/bin/sh
# someone else's filter" > "$SB/filter/label-crop"; chmod 755 "$SB/filter/label-crop"
sums > "$T/sc0"
rc=$(run coll-file --target Label_Printer --yes $EXTRA_FLAGS)
sums > "$T/sc1"
[ "$rc" != 0 ] && grep -q "not installed by cups-label-crop" "$T/coll-file.log" && ok "foreign filter file: install aborted" || { bad "foreign file rc=$rc"; tail "$T/coll-file.log"; }
same "$T/sc0" "$T/sc1" "foreign filter file: zero changes"
grep -q "someone else's filter" "$SB/filter/label-crop" && ok "foreign file left intact" || bad "foreign file modified"
[ ! -e /var/backups/cups-label-crop ] && ok "no backup dir on abort (nothing started)" || bad "backup dir created on abort"
rm -f "$SB/filter/label-crop"

lpadmin -p Label_Crop -v capture:/someoneelse -m raw -E 2>/dev/null; sleep 1
sums > "$T/sq0"
rc=$(run coll-queue --target Label_Printer --yes $EXTRA_FLAGS)
sums > "$T/sq1"
[ "$rc" != 0 ] && grep -q "already exists and is not a cups-label-crop queue" "$T/coll-queue.log" && ok "foreign queue named Label_Crop: aborted" || { bad "foreign queue rc=$rc"; tail "$T/coll-queue.log"; }
same "$T/sq0" "$T/sq1" "foreign queue: zero changes"
lpadmin -x Label_Crop; sleep 1

rc=$(run missing --target No_Such_Printer --yes $EXTRA_FLAGS)
[ "$rc" != 0 ] && grep -q "does not exist" "$T/missing.log" && ok "missing target: aborted without --allow-missing-target" || bad "missing target rc=$rc"
sums > "$T/sm"; normsums > "$T/n0"; keepconf n0; cupsctl > "$T/cupsctl-0"; queues_state > "$T/q0"
[ ! -e /var/backups/cups-label-crop ] && ok "missing target: nothing written" || bad "missing target wrote something"

# ------------------------------------------------------------- 3. install
rc=$(run install --target Label_Printer --yes $EXTRA_FLAGS)
if [ "$rc" = 0 ]; then ok "install exits 0"; else bad "install rc=$rc"; cat "$T/install.log"; fi
grep -q "verified: all .* other queue(s) unchanged" "$T/install.log" && ok "installer self-check: other queues unchanged" || bad "installer self-check"
grep -q "verified: test crop" "$T/install.log" && ok "installer self-test crop passed" || bad "self-test crop"
queues_state > "$T/q1"; same "$T/q0" "$T/q1" "independent check: existing queues, options, PPDs, default, sharing unchanged"
lpstat -v Label_Crop 2>/dev/null | grep -q "labelcrop:Label_Printer" && ok "Label_Crop -> labelcrop:Label_Printer" || bad "queue not created"
[ "$(cupsctl | sed -n 's/^_share_printers=//p')" = 0 ] && ok "server sharing left off (not enabled behind your back)" || bad "sharing changed"
grep -q "printer sharing is off" "$T/install.log" && ok "printed sharing instructions instead" || bad "no sharing note"
[ -f /var/lib/cups-label-crop/manifest ] && ok "manifest written" || bad "no manifest"
ls -d /var/backups/cups-label-crop/*/serverroot.tar.gz >/dev/null 2>&1 && ok "backup tarball of /etc/cups written" || bad "no backup"
# only additive: every pre-existing file in ServerBin untouched
comm -23 <(grep " $SB/" "$T/sm" | sort) <(sums | grep " $SB/" | sort) > "$T/sb-changed"
[ ! -s "$T/sb-changed" ] && ok "no pre-existing ServerBin file changed" || { bad "ServerBin files changed"; cat "$T/sb-changed"; }
for f in cupsd.conf cups-files.conf; do
    a=$(grep " /etc/cups/$f$" "$T/sm"); b=$(sums | grep " /etc/cups/$f$")
    [ "$a" = "$b" ] && ok "$f untouched" || bad "$f changed"
done

# ------------------------------------------------------------- 4. a real job is cropped and forwarded
for f in mock-vinted-a4-landscape mock-generic-letter; do lp -d Label_Crop "$SRC/tests/fixtures/$f.pdf" >/dev/null; done
for _ in $(seq 1 60); do [ "$(ls /tmp/capture/label-*.pdf 2>/dev/null | wc -l)" -ge 2 ] && break; sleep 0.5; done
INTERP=$(head -n1 "$SB/filter/label-crop" | sed 's/^#!//')
n=0
for f in /tmp/capture/label-*.pdf; do
    [ -f "$f" ] || continue
    if "$INTERP" -c 'import sys,pikepdf; pdf=pikepdf.Pdf.open(sys.argv[1]); b=pdf.pages[0].mediabox; sys.exit(0 if (round(float(b[2])-float(b[0])),round(float(b[3])-float(b[1])))==(288,432) else 1)' "$f"; then n=$((n+1)); fi
done
[ "$n" = 2 ] && ok "2 jobs cropped to 288x432 pt and forwarded to Label_Printer" || { bad "forwarded=$n"; lpstat -W all -o; tail -30 /var/log/cups/error_log; }
[ -z "$(ls /tmp/capture/office-* 2>/dev/null)" ] && ok "nothing went to other printers" || bad "other printer got jobs"

# ------------------------------------------------------------- 5. re-install is idempotent
cp /var/lib/cups-label-crop/manifest "$T/m1"; sums | grep -vE '/etc/cups/|/var/lib/' > "$T/f1"
rc=$(run reinstall --target Label_Printer --yes $EXTRA_FLAGS)
[ "$rc" = 0 ] && ok "re-install exits 0" || { bad "re-install rc=$rc"; tail -30 "$T/reinstall.log"; }
[ "$(grep -c '  unchanged ' "$T/reinstall.log")" = 5 ] && ok "re-install: all 5 files reported unchanged" || bad "re-install rewrote files: $(grep -E 'installed|unchanged' "$T/reinstall.log" | tr '\n' ';')"
sums | grep -vE '/etc/cups/|/var/lib/' > "$T/f2"; same "$T/f1" "$T/f2" "re-install: installed files identical"
diff <(grep -vE '^meta' "$T/m1" | sort) <(grep -vE '^meta' /var/lib/cups-label-crop/manifest | sort) >/dev/null && ok "re-install: manifest items identical" || bad "manifest changed"
[ "$(lpstat -v | grep -c labelcrop:)" = 1 ] && ok "still exactly one crop queue" || bad "duplicate crop queues"
queues_state > "$T/q2"; same "$T/q0" "$T/q2" "re-install: existing queues unchanged"

# upgrade refuses a file we installed that someone modified
echo "# local edit" >> /etc/cups-label-crop/label-crop.conf; sums > "$T/se0"
rc=$(run modified --target Label_Printer --yes $EXTRA_FLAGS); sums > "$T/se1"
[ "$rc" != 0 ] && grep -q "modified since" "$T/modified.log" && ok "modified own file: upgrade refused" || bad "modified file rc=$rc"
same "$T/se0" "$T/se1" "modified own file: zero changes"
sed -i '$d' /etc/cups-label-crop/label-crop.conf

# ------------------------------------------------------------- 6. uninstall restores the pre-install state
rc=$(run uninstall --uninstall --yes)
[ "$rc" = 0 ] && ok "uninstall exits 0" || { bad "uninstall rc=$rc"; cat "$T/uninstall.log"; }
normsums > "$T/n1"; keepconf n1; diff -r "$T/conf-n0" "$T/conf-n1" | sed "s/^/      conf: /"; same "$T/n0" "$T/n1" "uninstall: /etc/cups and ServerBin match pre-install (ignoring cupsd timestamps/.O)"
diff <(grep -vE '/etc/cups/|\.O$' "$T/sm") <(sums | grep -vE '/etc/cups/|\.O$') > "$T/exact.diff" && ok "uninstall: ServerBin + add-on paths byte-identical to pre-install (venv excepted if kept)" || { grep -q venv "$T/exact.diff" && ! grep -v venv "$T/exact.diff" | grep -q '^[<>]' && ok "uninstall: only the kept venv remains" || { bad "uninstall leftovers"; head -20 "$T/exact.diff"; }; }
queues_state > "$T/q3"; same "$T/q0" "$T/q3" "uninstall: existing queues unchanged"
! lpstat -v Label_Crop >/dev/null 2>&1 && ok "Label_Crop removed" || bad "Label_Crop still there"
[ ! -e /var/lib/cups-label-crop ] && [ ! -e /etc/cups-label-crop ] && ok "manifest and config removed" || bad "state left"
ls /var/backups/cups-label-crop/*/serverroot.tar.gz >/dev/null 2>&1 && ok "backups kept" || bad "backups removed"
rc=$(run uninstall2 --uninstall --yes); [ "$rc" != 0 ] && grep -q "nothing installed" "$T/uninstall2.log" && ok "second uninstall is a safe no-op" || bad "second uninstall rc=$rc"

# ------------------------------------------------------------- 7. missing target allowed + --enable-sharing
rc=$(run allow --target Not_Yet --allow-missing-target --enable-sharing --name Vinted_Label --display-name "Vinted Label" --yes $EXTRA_FLAGS)
[ "$rc" = 0 ] && ok "--allow-missing-target installs" || { bad "allow rc=$rc"; tail -30 "$T/allow.log"; }
[ "$(cupsctl | sed -n 's/^_share_printers=//p')" = 1 ] && ok "--enable-sharing turned sharing on" || bad "sharing not on"
lp -d Vinted_Label "$SRC/tests/fixtures/mock-vinted-a4-portrait.pdf" >/dev/null; sleep 4
lpstat -o Vinted_Label | grep -q Vinted_Label && ok "job waits while target is missing" || bad "job vanished"
cancel -a Vinted_Label 2>/dev/null
rc=$(run uninstall3 --uninstall --yes --remove-venv)
[ "$rc" = 0 ] && ok "uninstall after allow-missing" || bad "uninstall3 rc=$rc"
[ "$(cupsctl | sed -n 's/^_share_printers=//p')" = 0 ] && ok "uninstall turned sharing back off" || bad "sharing not reverted"
queues_state > "$T/q4"; same "$T/q0" "$T/q4" "final: existing queues unchanged"
cupsctl > "$T/cupsctl-final"; same "$T/cupsctl-0" "$T/cupsctl-final" "final: all cupsctl settings back to pre-install values"
normsums | grep -v ' /etc/cups/cupsd.conf$' > "$T/n2"; keepconf n2; diff -r "$T/conf-n0" "$T/conf-n2" | sed "s/^/      conf: /"; # cupsctl restarts cupsd, which rewrites classes.conf with mode 600; compare content only here
same <(grep -v " /etc/cups/cupsd.conf$" "$T/n0" | cut -d' ' -f3-) <(cut -d' ' -f3- "$T/n2") "final: /etc/cups (except cupsctl-rewritten cupsd.conf) and ServerBin content match pre-install"
[ ! -e /opt/cups-label-crop ] && ok "--remove-venv: /opt/cups-label-crop gone" || bad "/opt/cups-label-crop left: $(ls -A /opt/cups-label-crop)"

echo "Passed $PASS  Failed $FAIL"
[ "$FAIL" = 0 ]
