#!/bin/bash
# cups-label-crop add-on installer for an EXISTING CUPS server.
# Copyright (C) 2026 cups-label-crop contributors. GPL-3.0-or-later.
# https://github.com/Dyingmisery/cups-label-crop
#
# Adds one "Label Crop" queue (plus its filter and backend) to a CUPS server
# you already run. It is additive only:
#   * never edits cupsd.conf, cups-files.conf or printers.conf by hand
#   * never touches other queues, and never restarts cupsd
#   * never overwrites a file it did not install (checked via a manifest)
#   * backs up /etc/cups before changing anything
#   * records everything it creates, so --uninstall removes exactly that
#
# Always start with:  sudo bash addon/install.sh --dry-run --target YOUR_PRINTER
# Run with --help for all options.
set -euo pipefail
umask 022

VERSION=0.1.0
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$SELF_DIR/.." && pwd)

# ------------------------------------------------------------------ paths
PREFIX=/opt/cups-label-crop
CONF_DIR=/etc/cups-label-crop
CONF_FILE=$CONF_DIR/label-crop.conf
STATE_DIR=/var/lib/cups-label-crop
MANIFEST=$STATE_DIR/manifest
BACKUP_ROOT=/var/backups/cups-label-crop
VENV=$PREFIX/venv
VENV_MARK=$VENV/.cups-label-crop-venv
PIKEPDF_SPEC='pikepdf>=6,<11'
MIN_PY=3.9

SRC_FILTER=$REPO_DIR/src/label-crop
SRC_BACKEND=$REPO_DIR/src/labelcrop
SRC_PPD=$REPO_DIR/src/label-crop.ppd
SRC_FIXTURE=$REPO_DIR/tests/fixtures/mock-vinted-a4-landscape.pdf

# ------------------------------------------------------------------ options
TARGET=""
NAME=Label_Crop
DISPLAY_NAME="Label Crop"
SIZE=4x6
PADDING=3
ROTATE=auto
SHEET=A4
DRY_RUN=0
YES=0
UNINSTALL=0
REMOVE_VENV=0
INSTALL_DEPS=0
NO_VENV=0
ALLOW_MISSING_TARGET=0
ENABLE_SHARING=0

usage() {
    cat <<USAGE
cups-label-crop add-on installer $VERSION

Usage: sudo bash addon/install.sh --target QUEUE [options]
       sudo bash addon/install.sh --uninstall [--remove-venv] [--dry-run]

Install options:
  --target QUEUE          existing CUPS queue of your label printer (required)
  --name NAME             crop queue name, no spaces (default: Label_Crop)
  --display-name TEXT     name shown in print dialogs (default: "Label Crop")
  --size WxH              label size in inches (default: 4x6)
  --padding PT            margin around the label in points (default: 3)
  --rotate MODE           auto, 0, 90, 180 or 270 (default: auto)
  --sheet A4|Letter       sheet size the crop queue advertises (default: A4)
  --allow-missing-target  install even if --target does not exist yet
  --enable-sharing        turn on CUPS printer sharing (cupsctl --share-printers);
                          recorded so --uninstall turns it back off
  --install-deps          install missing Python libraries with the distro
                          package manager instead of a private venv
  --no-venv               never create a venv; fail if pikepdf is missing

General:
  --dry-run               show every action, change nothing
  --yes, -y               do not ask for confirmation
  --uninstall             remove everything this installer created
  --remove-venv           with --uninstall, also delete $VENV
  --help, -h              this help

Files: filter and backend in CUPS's ServerBin, $CONF_FILE,
$PREFIX, manifest $MANIFEST,
backups in $BACKUP_ROOT/<timestamp>/.
USAGE
}

die()  { echo "ERROR: $*" >&2; exit 1; }
need_arg() { if [ $# -lt 2 ] || [ -z "$2" ]; then die "$1 needs a value (see --help)"; fi; }

while [ $# -gt 0 ]; do
    case "$1" in
        --target) need_arg "$@"; TARGET=$2; shift 2 ;;
        --name) need_arg "$@"; NAME=$2; shift 2 ;;
        --display-name) need_arg "$@"; DISPLAY_NAME=$2; shift 2 ;;
        --size) need_arg "$@"; SIZE=$2; shift 2 ;;
        --padding) need_arg "$@"; PADDING=$2; shift 2 ;;
        --rotate) need_arg "$@"; ROTATE=$2; shift 2 ;;
        --sheet) need_arg "$@"; SHEET=$2; shift 2 ;;
        --allow-missing-target) ALLOW_MISSING_TARGET=1; shift ;;
        --enable-sharing) ENABLE_SHARING=1; shift ;;
        --install-deps) INSTALL_DEPS=1; shift ;;
        --no-venv) NO_VENV=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --yes|-y) YES=1; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        --remove-venv) REMOVE_VENV=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) die "unknown option '$1' (see --help)" ;;
    esac
done

# ------------------------------------------------------------------ output helpers
ERRORS=()
WARNINGS=()
PLAN=()
fail()  { ERRORS+=("$*"); }
warn()  { WARNINGS+=("$*"); }
plan()  { PLAN+=("$*"); }
info()  { echo "  $*"; }
say()   { echo "[cups-label-crop] $*"; }
loud()  {
    echo >&2
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
    printf '!! %s\n' "$@" >&2
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
    echo >&2
}

report_and_abort_if_errors() {
    local w e
    if [ ${#WARNINGS[@]} -gt 0 ]; then
        echo; echo "Warnings:"
        for w in "${WARNINGS[@]}"; do echo "  - $w"; done
    fi
    if [ ${#ERRORS[@]} -gt 0 ]; then
        echo; echo "Preflight FAILED. Nothing was changed:" >&2
        for e in "${ERRORS[@]}"; do echo "  x $e" >&2; done
        exit 2
    fi
}

sha() { sha256sum "$1" | cut -d' ' -f1; }

# ------------------------------------------------------------------ manifest
# Tab separated. Kinds:
#   meta KEY VALUE | file SHA256 PATH | dir PATH | queue NAME
#   setting share_printers PREVIOUS | venv PATH | pkg MANAGER NAME
declare -A M_FILE=()
M_DIRS=()
M_QUEUES=()
M_SETTINGS=()
M_VENV=""
M_PKGS=()
declare -A M_META=()

manifest_load() {
    [ -f "$MANIFEST" ] || return 0
    local kind a b
    while IFS=$'\t' read -r kind a b; do
        case "$kind" in
            meta) M_META[$a]=$b ;;
            file) M_FILE[$b]=$a ;;
            dir) M_DIRS+=("$a") ;;
            queue) M_QUEUES+=("$a") ;;
            setting) M_SETTINGS+=("$a=$b") ;;
            venv) M_VENV=$a ;;
            pkg) M_PKGS+=("$a $b") ;;
            ''|'#'*) ;;
            *) echo "WARN: unknown manifest line: $kind" >&2 ;;
        esac
    done < "$MANIFEST"
}

in_list() { local x=$1; shift; local y; for y in "$@"; do [ "$x" = "$y" ] && return 0; done; return 1; }

manifest_save() {
    local tmp p d q s k
    mkdir -p "$STATE_DIR"
    tmp=$(mktemp "$STATE_DIR/.manifest.XXXXXX")
    {
        echo "# cups-label-crop add-on manifest v1. Written by addon/install.sh; do not edit."
        for k in "${!M_META[@]}"; do printf 'meta\t%s\t%s\n' "$k" "${M_META[$k]}"; done
        for d in "${M_DIRS[@]}"; do printf 'dir\t%s\n' "$d"; done
        for p in "${!M_FILE[@]}"; do printf 'file\t%s\t%s\n' "${M_FILE[$p]}" "$p"; done
        for q in "${M_QUEUES[@]}"; do printf 'queue\t%s\n' "$q"; done
        for s in "${M_SETTINGS[@]}"; do printf 'setting\t%s\t%s\n' "${s%%=*}" "${s#*=}"; done
        [ -n "$M_VENV" ] && printf 'venv\t%s\n' "$M_VENV"
        for p in "${M_PKGS[@]}"; do printf 'pkg\t%s\t%s\n' "${p%% *}" "${p#* }"; done
    } > "$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$MANIFEST"
}

# ------------------------------------------------------------------ CUPS discovery (read-only)
SERVERBIN=""
SERVERROOT=""
CUPS_USER="lp"

find_cups() {
    local c
    for c in lpstat lpadmin lp cupsctl cupsaccept cupsenable; do
        command -v "$c" >/dev/null 2>&1 || fail "'$c' not found. Is CUPS installed? (Debian/Ubuntu: cups and cups-client)"
    done
    if command -v cups-config >/dev/null 2>&1; then
        SERVERBIN=$(cups-config --serverbin 2>/dev/null || true)
        SERVERROOT=$(cups-config --serverroot 2>/dev/null || true)
    fi
    if [ -z "$SERVERBIN" ] || [ ! -d "$SERVERBIN/backend" ]; then
        SERVERBIN=""
        for c in /usr/lib/cups /usr/libexec/cups /usr/local/lib/cups /usr/lib64/cups; do
            if [ -d "$c/backend" ] && [ -d "$c/filter" ]; then SERVERBIN=$c; break; fi
        done
    fi
    [ -n "$SERVERROOT" ] && [ -d "$SERVERROOT" ] || SERVERROOT=/etc/cups
    if [ -z "$SERVERBIN" ]; then
        fail "could not find CUPS's ServerBin directory (tried cups-config --serverbin, /usr/lib/cups, /usr/libexec/cups)"
    else
        [ -d "$SERVERBIN/filter" ] || fail "$SERVERBIN/filter is missing"
        [ -d "$SERVERBIN/backend" ] || fail "$SERVERBIN/backend is missing"
    fi
    [ -f "$SERVERROOT/cupsd.conf" ] || fail "$SERVERROOT/cupsd.conf not found (CUPS ServerRoot)"
    if [ -f "$SERVERROOT/cups-files.conf" ]; then
        c=$(sed -n 's/^[[:space:]]*User[[:space:]]\+\([^[:space:]]*\).*/\1/p' "$SERVERROOT/cups-files.conf" | tail -n 1)
        [ -n "$c" ] && CUPS_USER=$c
        if grep -qiE '^[[:space:]]*ServerBin[[:space:]]' "$SERVERROOT/cups-files.conf"; then
            c=$(sed -n 's/^[[:space:]]*ServerBin[[:space:]]\+\([^[:space:]]*\).*/\1/Ip' "$SERVERROOT/cups-files.conf" | tail -n 1)
            if [ -n "$c" ] && [ "$c" != "$SERVERBIN" ]; then
                if [ -d "$c/backend" ]; then SERVERBIN=$c; else fail "cups-files.conf sets ServerBin $c but it has no backend/ dir"; fi
            fi
        fi
    fi
    id "$CUPS_USER" >/dev/null 2>&1 || CUPS_USER=root
    if ! lpstat -r 2>/dev/null | grep -qi "is running"; then
        fail "cupsd is not running (lpstat -r). Start CUPS first."
    fi
}

list_queues() { { lpstat -v 2>/dev/null || true; } | sed -n 's/^device for \([^:]*\): .*/\1/p'; }
queue_uri()  { { lpstat -v "$1" 2>/dev/null || true; } | sed -n 's/^device for [^:]*: //p' | head -n 1; }
queue_exists() { list_queues | grep -qxF -- "$1"; }

# A queue is "ours" if it is in the manifest, or it uses the labelcrop:
# backend AND its PPD carries our marker.
queue_is_ours() {
    local q=$1
    in_list "$q" "${M_QUEUES[@]}" && return 0
    case "$(queue_uri "$q")" in labelcrop:*) ;; *) return 1 ;; esac
    grep -q 'cups-label-crop-file: label-crop.ppd' "$SERVERROOT/ppd/$q.ppd" 2>/dev/null
}

run_as_cups_user() {
    if [ "$CUPS_USER" = root ]; then "$@"; return; fi
    if command -v setpriv >/dev/null 2>&1; then
        setpriv --reuid="$CUPS_USER" --regid="$(id -g "$CUPS_USER")" --init-groups -- "$@"
    elif command -v runuser >/dev/null 2>&1; then
        runuser -u "$CUPS_USER" -- "$@"
    else
        "$@"
    fi
}

# cupsctl makes cupsd restart; wait until it answers again before reading state.
wait_cupsd() {
    sleep 1
    for _ in $(seq 1 60); do
        if lpstat -r 2>/dev/null | grep -qi "is running" && lpstat -v >/dev/null 2>&1; then sleep 1; return 0; fi
        sleep 0.5
    done
    echo "WARN: cupsd did not answer within 30 s after cupsctl" >&2
}

in_container() {
    if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then return 0; fi
    grep -qaE 'docker|kubepods|containerd|lxc|podman' /proc/1/cgroup 2>/dev/null && return 0
    return 1
}

# Is PATH inside a bind mount / volume (i.e. survives container recreate)?
on_mount() {
    local path=$1 mp best=""
    while read -r mp; do
        case "$path/" in "$mp"/*) [ ${#mp} -gt ${#best} ] && best=$mp ;; esac
    done < <(awk '{print $5}' /proc/self/mountinfo 2>/dev/null | grep -v '^/$')
    [ -n "$best" ]
}

# Snapshot of every queue except ours: URI, PPD checksum, options. Used to
# prove the install did not change anything else.
snapshot_queues() {
    local q
    { lpstat -d 2>/dev/null || true; } | sed 's/^/default: /'
    while read -r q; do
        [ -z "$q" ] && continue
        if [ "$q" = "$NAME" ] || in_list "$q" "${M_QUEUES[@]}"; then continue; fi
        echo "== $q"
        echo "uri: $(queue_uri "$q")"
        if [ -f "$SERVERROOT/ppd/$q.ppd" ]; then echo "ppd-sha256: $(sha "$SERVERROOT/ppd/$q.ppd")"; else echo "ppd: none"; fi
        { lpoptions -p "$q" -l 2>/dev/null || true; } | sed 's/^/ppd-option: /'
        { lpoptions -p "$q" 2>/dev/null || true; } | tr ' ' '\n' \
            | grep -vE '^(printer-state|printer-state-change-time|printer-state-reasons|marker-|printer-commands|printer-type|job-|printer-up-time|queued-job-count)' \
            | sed 's/^/attr: /'
    done < <(list_queues | sort)
}

# cupsctl --no-share-printers also drops settings such as BrowseLocalProtocols.
# Put back any cupsctl-managed setting that differs from before --enable-sharing.
restore_cupsctl_settings() {
    local before=$1 line key val cur
    [ -n "$before" ] && [ -f "$before" ] || return 0
    while IFS= read -r line; do
        key=${line%%=*}; val=${line#*=}
        case "$key" in _*|'') continue ;; esac
        cur=$(cupsctl 2>/dev/null | sed -n "s/^$key=//p")
        if [ "$cur" != "$val" ]; then
            cupsctl "$key=$val" && wait_cupsd && say "restored $key=$val"
        fi
    done < "$before"
    say "note: cupsctl rewrites cupsd.conf, so its comments/layout may differ from before --enable-sharing. The original is in the backup: $(dirname "$before")/serverroot.tar.gz"
}

# ------------------------------------------------------------------ uninstall
do_uninstall() {
    [ "$(id -u)" -eq 0 ] || die "run as root (sudo)"
    find_cups
    report_and_abort_if_errors
    [ -f "$MANIFEST" ] || die "no manifest at $MANIFEST: nothing installed by this script (nothing changed)"
    manifest_load
    local p q s d cur
    echo "Uninstall plan (only items in $MANIFEST):"
    for q in "${M_QUEUES[@]}"; do echo "  - delete queue $q (lpadmin -x)"; done
    for p in "${!M_FILE[@]}"; do echo "  - remove $p"; done
    for s in "${M_SETTINGS[@]}"; do echo "  - restore setting ${s%%=*} to ${s#*=} (cupsctl)"; done
    for d in "${M_DIRS[@]}"; do echo "  - remove dir $d if empty"; done
    if [ -n "$M_VENV" ]; then
        if [ "$REMOVE_VENV" = 1 ]; then echo "  - remove venv $M_VENV"; else echo "  - keep venv $M_VENV (use --remove-venv to delete it)"; fi
    fi
    for p in "${M_PKGS[@]}"; do echo "  - keep distro package ${p#* } (installed with --install-deps; other software may use it)"; done
    echo "  - keep backups in $BACKUP_ROOT"
    if [ "$DRY_RUN" = 1 ]; then echo; echo "Dry run: nothing changed."; exit 0; fi
    confirm "Uninstall cups-label-crop add-on?"

    local before after
    before=$(mktemp); after=$(mktemp)
    snapshot_queues > "$before"
    for q in "${M_QUEUES[@]}"; do
        if queue_exists "$q"; then
            case "$(queue_uri "$q")" in
                labelcrop:*) lpadmin -x "$q" && say "deleted queue $q" ;;
                *) say "WARN: queue $q no longer uses labelcrop:, so it is not ours any more; left alone" ;;
            esac
        fi
    done
    for p in "${!M_FILE[@]}"; do
        if [ -f "$p" ]; then
            if [ "$(sha "$p")" = "${M_FILE[$p]}" ]; then rm -f "$p" && say "removed $p"
            else say "WARN: $p was modified after install; left in place for you to check"; fi
        fi
    done
    for s in "${M_SETTINGS[@]}"; do
        case "$s" in
            share_printers=0)
                cur=$(cupsctl 2>/dev/null | sed -n 's/^_share_printers=//p')
                if [ "$cur" = 1 ]; then
                    cupsctl --no-share-printers && wait_cupsd && say "printer sharing turned back off"
                    restore_cupsctl_settings "${M_META[cupsctl_before]:-}"
                fi ;;
        esac
    done
    if [ -n "$M_VENV" ] && [ "$REMOVE_VENV" = 1 ] && [ -f "$M_VENV/.cups-label-crop-venv" ]; then
        rm -rf "$M_VENV" && say "removed venv $M_VENV"
    fi
    # Directories: deepest first, only if empty
    for d in $(printf '%s\n' "${M_DIRS[@]}" | awk '{print length, $0}' | sort -rn | cut -d' ' -f2-); do
        [ -d "$d" ] && rmdir "$d" 2>/dev/null && say "removed dir $d"
    done
    rm -f "$MANIFEST"
    rmdir "$STATE_DIR" 2>/dev/null || true
    snapshot_queues > "$after"
    if ! diff -u "$before" "$after" >/dev/null; then
        loud "Other queues look different after uninstall. This should not happen." \
             "Diff:" "$(diff -u "$before" "$after" || true)"
    fi
    rm -f "$before" "$after"
    for p in "${M_PKGS[@]}"; do say "note: distro package ${p#* } is still installed; remove it with ${p%% *} if nothing else needs it"; done
    say "uninstall complete. Backups remain in $BACKUP_ROOT."
    exit 0
}

confirm() {
    [ "$YES" = 1 ] && return 0
    local ans=""
    if [ -t 0 ]; then
        read -r -p "$1 [y/N] " ans || true
    elif { exec 3</dev/tty; } 2>/dev/null; then
        printf '%s [y/N] ' "$1" > /dev/tty
        read -r ans <&3 || true
        exec 3<&-
    else
        die "not interactive: re-run with --yes to confirm (nothing was changed)"
    fi
    case "$ans" in y|Y|yes|YES) return 0 ;; esac
    echo "Aborted. Nothing was changed."
    exit 1
}

[ "$UNINSTALL" = 1 ] && do_uninstall

# ================================================================== install preflight (read-only)
echo "cups-label-crop add-on installer $VERSION$([ "$DRY_RUN" = 1 ] && echo ' (dry run)')"
echo

[ "$(id -u)" -eq 0 ] || die "run as root (sudo). Nothing was changed."

for f in "$SRC_FILTER" "$SRC_BACKEND" "$SRC_PPD" "$SRC_FIXTURE"; do
    [ -f "$f" ] || die "missing $f. Run this script from a full copy of the cups-label-crop repository."
done
# Integrity: the files we are about to install must match addon/SHA256SUMS
if [ -f "$SELF_DIR/SHA256SUMS" ]; then
    if ( cd "$REPO_DIR" && grep -v ' addon/install.sh$' "$SELF_DIR/SHA256SUMS" | sha256sum -c --quiet - ) >/dev/null 2>&1; then
        info "source files match addon/SHA256SUMS"
    else
        die "the source files do not match addon/SHA256SUMS (corrupted or modified download?). Nothing was changed."
    fi
fi
for c in sha256sum tar awk sed grep diff mktemp; do
    command -v "$c" >/dev/null 2>&1 || fail "required tool '$c' not found"
done

# --- settings
valid_queue_name() { [[ -n "$1" && ${#1} -le 127 && "$1" != *[[:space:]/\#\'\"\\]* ]]; }
valid_queue_name "$NAME" || fail "--name '$NAME' is not a valid queue name (no spaces, /, #, quotes)"
[ -n "$TARGET" ] || fail "--target is required: the existing queue of your label printer (see: lpstat -v)"
[ -z "$TARGET" ] || valid_queue_name "$TARGET" || fail "--target '$TARGET' is not a valid queue name"
[ "$TARGET" != "$NAME" ] || fail "--target and --name must differ"
[[ "$SIZE" =~ ^([0-9]+([.][0-9]+)?)x([0-9]+([.][0-9]+)?)$ ]] || fail "--size must look like 4x6 (inches)"
W_IN=${BASH_REMATCH[1]:-4}; H_IN=${BASH_REMATCH[3]:-6}
[[ "$PADDING" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "--padding must be a number of points"
case "$ROTATE" in auto|0|90|180|270) ;; *) fail "--rotate must be auto, 0, 90, 180 or 270" ;; esac
case "$SHEET" in A4|Letter) ;; *) fail "--sheet must be A4 or Letter" ;; esac
case "$DISPLAY_NAME" in *[\"\\]*) fail "--display-name must not contain quotes or backslashes" ;; esac

# --- this is not our own image
if [ -f /usr/local/bin/entrypoint.sh ] && grep -q 'cups-label-crop container entrypoint' /usr/local/bin/entrypoint.sh 2>/dev/null; then
    die "this is the cups-label-crop container image; it already has the crop queue. Use its settings instead."
fi

# --- CUPS
find_cups
manifest_load
if [ -f "$MANIFEST" ]; then
    MODE=upgrade
    [ -z "${M_META[serverbin]:-}" ] || [ "${M_META[serverbin]}" = "$SERVERBIN" ] \
        || fail "manifest says ServerBin was ${M_META[serverbin]}, but CUPS now uses $SERVERBIN. Run --uninstall first."
else
    MODE=install
fi

DST_FILTER=$SERVERBIN/filter/label-crop
DST_BACKEND=$SERVERBIN/backend/labelcrop
DST_PPD=$PREFIX/label-crop.ppd
DST_FIXTURE=$PREFIX/test/mock-vinted-a4-landscape.pdf

# --- python
PY_SYS=$(command -v python3 2>/dev/null || true)
# Stable path for the filter's #! line (e.g. Fedora's /usr/sbin is the same dir as /usr/bin)
if [ -n "$PY_SYS" ] && [ -x /usr/bin/python3 ] && [ /usr/bin/python3 -ef "$PY_SYS" ]; then PY_SYS=/usr/bin/python3; fi
INTERP=""
DEP_MODE=""        # system | venv-existing | venv-new | pkg
PKG_MGR=""
PKG_LIST=()
py_ok_version() { "$1" -c "import sys; sys.exit(0 if sys.version_info >= tuple(int(x) for x in '$MIN_PY'.split('.')) else 1)" 2>/dev/null; }
py_has_pikepdf() { run_as_cups_user "$1" -c 'import pikepdf, sys; v=tuple(int(x) for x in pikepdf.__version__.split(".")[:2]); sys.exit(0 if v >= (6,0) else 3)' >/dev/null 2>&1; }

detect_pkg_mgr() {
    if command -v apt-get >/dev/null 2>&1; then PKG_MGR=apt-get; PKG_LIST=(python3 python3-pikepdf poppler-utils)
    elif command -v dnf >/dev/null 2>&1; then PKG_MGR=dnf; PKG_LIST=(python3 python3-pikepdf poppler-utils)
    elif command -v zypper >/dev/null 2>&1; then PKG_MGR=zypper; PKG_LIST=(python3 python3-pikepdf poppler-tools)
    elif command -v pacman >/dev/null 2>&1; then PKG_MGR=pacman; PKG_LIST=(python python-pikepdf poppler)
    elif command -v apk >/dev/null 2>&1; then PKG_MGR=apk; PKG_LIST=(python3 py3-pikepdf poppler-utils)
    fi
}

if [ -n "$PY_SYS" ] && ! py_ok_version "$PY_SYS"; then
    warn "system python3 is older than $MIN_PY"
    PY_SYS_OK=0
else
    PY_SYS_OK=1
fi

if [ -x "$VENV/bin/python3" ] && [ -f "$VENV_MARK" ] && py_has_pikepdf "$VENV/bin/python3"; then
    DEP_MODE=venv-existing; INTERP=$VENV/bin/python3
elif [ -n "$PY_SYS" ] && [ "$PY_SYS_OK" = 1 ] && py_has_pikepdf "$PY_SYS"; then
    DEP_MODE=system; INTERP=$PY_SYS
elif [ "$INSTALL_DEPS" = 1 ]; then
    detect_pkg_mgr
    if [ -z "$PKG_MGR" ]; then fail "--install-deps: no supported package manager (apt-get, dnf, zypper, pacman, apk)"
    else DEP_MODE=pkg; INTERP=/usr/bin/python3; fi
elif [ "$NO_VENV" = 1 ]; then
    fail "python3 with pikepdf >= 6 not found, and --no-venv was given. Install your distro's pikepdf package (e.g. python3-pikepdf) or drop --no-venv."
elif [ -z "$PY_SYS" ]; then
    fail "python3 is not installed. Install it (e.g. apt-get install python3 python3-venv), or use --install-deps."
elif [ "$PY_SYS_OK" = 0 ]; then
    fail "python3 $("$PY_SYS" -V 2>&1) is too old (need >= $MIN_PY)"
elif ! "$PY_SYS" -c 'import venv, ensurepip' >/dev/null 2>&1; then
    fail "pikepdf is missing and python3 cannot create a venv (Debian/Ubuntu: apt-get install python3-venv). Or use --install-deps to install python3-pikepdf from your distro."
else
    DEP_MODE=venv-new; INTERP=$VENV/bin/python3
fi

if ! command -v pdftoppm >/dev/null 2>&1 && ! command -v gs >/dev/null 2>&1; then
    warn "neither pdftoppm (poppler-utils) nor gs (ghostscript) found: normal label PDFs work, but the fallback for flattened/scanned PDFs is unavailable"
fi

# --- target queue
if [ -n "$TARGET" ] && ! queue_exists "$TARGET"; then
    if [ "$ALLOW_MISSING_TARGET" = 1 ]; then
        warn "target queue '$TARGET' does not exist yet. Jobs to '$DISPLAY_NAME' will wait and retry until you add it with exactly that name."
    else
        fail "target queue '$TARGET' does not exist. Existing queues: $(list_queues | tr '\n' ' '). Add your printer first, or pass --allow-missing-target."
    fi
fi
if [ -n "$TARGET" ] && queue_exists "$TARGET"; then
    case "$(queue_uri "$TARGET")" in labelcrop:*) fail "--target '$TARGET' is itself a crop queue (would loop)" ;; esac
fi

# --- collisions: never overwrite a file or queue we did not create
check_path() {
    # check_path PATH MARKER-TEXT
    local p=$1 mark=$2
    [ -e "$p" ] || [ -L "$p" ] || return 0
    if [ -n "${M_FILE[$p]:-}" ]; then
        if [ "$(sha "$p")" != "${M_FILE[$p]}" ]; then
            fail "$p was installed by us but has been modified since (checksum differs). Inspect it, then move it away or run --uninstall."
        fi
        return 0
    fi
    if [ -L "$p" ] || [ ! -f "$p" ]; then fail "$p exists and is not a regular file we installed; refusing to touch it"; return 0; fi
    if grep -q "cups-label-crop-file: $mark" "$p" 2>/dev/null; then
        warn "$p is a cups-label-crop file from an earlier install without a manifest (e.g. a recreated container); it will be replaced"
        return 0
    fi
    fail "$p already exists and was not installed by cups-label-crop. Refusing to overwrite a foreign file."
}
check_path "$DST_FILTER" label-crop
check_path "$DST_BACKEND" labelcrop
check_path "$DST_PPD" label-crop.ppd
check_path "$CONF_FILE" label-crop.conf
if [ -e "$DST_FIXTURE" ] && [ -z "${M_FILE[$DST_FIXTURE]:-}" ] && [ "$MODE" = install ]; then
    cmp -s "$DST_FIXTURE" "$SRC_FIXTURE" || fail "$DST_FIXTURE exists and is not ours"
fi
if [ -e "$PREFIX" ] && [ "$MODE" = install ]; then
    # Allowed only if it holds nothing but files we recognise (a kept venv, our files)
    while read -r entry; do
        case "$entry" in
            venv) [ -f "$VENV_MARK" ] || fail "$VENV exists and is not a cups-label-crop venv" ;;
            label-crop.ppd|test) ;;
            *) fail "$PREFIX already exists and contains '$entry', which is not ours. Refusing to use it." ;;
        esac
    done < <(ls -A "$PREFIX" 2>/dev/null)
fi
if [ -e "$CONF_DIR" ] && [ ! -d "$CONF_DIR" ]; then fail "$CONF_DIR exists and is not a directory"; fi
if queue_exists "$NAME"; then
    if queue_is_ours "$NAME"; then
        [ "$MODE" = install ] && warn "queue $NAME is a cups-label-crop queue from an earlier install; it will be updated"
    else
        fail "a queue named '$NAME' already exists and is not a cups-label-crop queue ($(queue_uri "$NAME")). Pick another --name."
    fi
fi
OLD_QUEUES=()
for q in "${M_QUEUES[@]}"; do [ "$q" != "$NAME" ] && OLD_QUEUES+=("$q"); done

# --- sharing (read-only check)
SHARE_NOW=$(cupsctl 2>/dev/null | sed -n 's/^_share_printers=//p' || true)
SHARING_ACTION=none
if [ "$SHARE_NOW" != 1 ]; then
    if [ "$ENABLE_SHARING" = 1 ]; then SHARING_ACTION=enable
    else warn "CUPS printer sharing is off, so phones will not see '$DISPLAY_NAME' over AirPrint. To turn it on yourself: sudo cupsctl --share-printers  (or re-run with --enable-sharing, which --uninstall reverts)"; fi
fi

# --- containers
if in_container; then
    msg="running inside a container. The add-on lives in the container's filesystem:"
    on_mount "$SERVERBIN" || msg="$msg $SERVERBIN is NOT on a volume (filter/backend vanish when the container is recreated);"
    on_mount "$SERVERROOT" || msg="$msg $SERVERROOT is NOT on a volume (the queue vanishes on recreate);"
    on_mount "$STATE_DIR" || on_mount /var/lib || msg="$msg the manifest in $STATE_DIR is not on a volume;"
    warn "$msg after an image update re-run this installer (it is safe to repeat). For Docker/Unraid the all-in-one cups-label-crop image is the better option."
fi

# --- build the plan
plan "back up $SERVERROOT (tar), lpstat -v, cupsctl settings and PPD checksums to $BACKUP_ROOT/<timestamp>/"
case "$DEP_MODE" in
    system) plan "use system Python $INTERP (pikepdf already installed): nothing to install" ;;
    venv-existing) plan "use existing private venv $VENV" ;;
    venv-new) plan "create private venv $VENV and pip install '$PIKEPDF_SPEC' into it (system Python is not modified; needs internet access to PyPI)" ;;
    pkg) plan "install distro packages with $PKG_MGR: ${PKG_LIST[*]}" ;;
esac
plan "install filter  $DST_FILTER (interpreter $INTERP)"
plan "install backend $DST_BACKEND"
plan "install $DST_PPD and self-test file $DST_FIXTURE"
plan "write $CONF_FILE (target $TARGET, ${W_IN}x${H_IN} in, padding $PADDING pt, rotate $ROTATE)"
if queue_exists "$NAME"; then plan "update our queue $NAME via lpadmin"
else plan "create queue $NAME (\"$DISPLAY_NAME\") via lpadmin -P $DST_PPD -v labelcrop:$TARGET (shared, retry on error)"; fi
for q in "${OLD_QUEUES[@]}"; do plan "delete our old crop queue $q (renamed to $NAME)"; done
[ "$SHARING_ACTION" = enable ] && plan "turn on printer sharing with cupsctl --share-printers (recorded; --uninstall turns it off again)"
plan "record everything in $MANIFEST"
plan "verify: all other queues unchanged (URI, PPD checksum, options), and test-crop a sample sheet"
plan "will NOT edit cupsd.conf/printers.conf, touch other queues, or restart cupsd"

echo "Detected: CUPS ServerBin $SERVERBIN, ServerRoot $SERVERROOT, filter user $CUPS_USER, mode $MODE"
echo "Existing queues: $(list_queues | tr '\n' ' ')"
report_and_abort_if_errors
echo
echo "Plan:"
for p in "${PLAN[@]}"; do echo "  - $p"; done
echo

if [ "$DRY_RUN" = 1 ]; then
    echo "Dry run: nothing was changed."
    exit 0
fi
confirm "Proceed with these changes?"

# ================================================================== install (changes start here)
TS=$(date +%Y%m%d-%H%M%S)
BACKUP=$BACKUP_ROOT/$TS
FAILED_STEP="start"
on_error() {
    loud "Install FAILED during: $FAILED_STEP" \
         "Everything created so far is recorded in $MANIFEST." \
         "Roll back with:  sudo bash $SELF_DIR/install.sh --uninstall --yes" \
         "Your CUPS config backup is in $BACKUP (restore: see $BACKUP/RESTORE.txt)"
}
trap on_error ERR

FAILED_STEP="backup"
mkdir -p "$BACKUP_ROOT" && chmod 700 "$BACKUP_ROOT"
mkdir -p "$BACKUP"
tar -C "$(dirname "$SERVERROOT")" -czf "$BACKUP/serverroot.tar.gz" "$(basename "$SERVERROOT")"
{ lpstat -v 2>/dev/null || true; } > "$BACKUP/lpstat-v.txt"
{ cupsctl 2>/dev/null || true; } > "$BACKUP/cupsctl.txt"
if [ -d "$SERVERROOT/ppd" ]; then ( cd "$SERVERROOT/ppd" && { sha256sum ./*.ppd 2>/dev/null || true; } ); fi > "$BACKUP/ppd.sha256"
snapshot_queues > "$BACKUP/queues-before.txt"
[ -f "$MANIFEST" ] && cp "$MANIFEST" "$BACKUP/manifest-before"
cat > "$BACKUP/RESTORE.txt" <<RESTORE
cups-label-crop add-on backup taken $TS before install/upgrade.

Normally you never need this: 'sudo bash addon/install.sh --uninstall' removes
only what the add-on created. If something else looks wrong:

  sudo systemctl stop cups            # or: service cups stop / kill cupsd in a container
  sudo tar -C $(dirname "$SERVERROOT") -xzf $BACKUP/serverroot.tar.gz
  sudo systemctl start cups

Queues before install: lpstat-v.txt. Settings: cupsctl.txt.
RESTORE
say "backup written to $BACKUP"
M_META[version]=$VERSION
M_META[serverbin]=$SERVERBIN
M_META[serverroot]=$SERVERROOT
M_META[last_backup]=$BACKUP
M_META[installed]=$(date -Iseconds)

mkdir_tracked() {
    local d=$1
    if [ ! -d "$d" ]; then
        mkdir -p "$d"
        in_list "$d" "${M_DIRS[@]}" || M_DIRS+=("$d")
        manifest_save
    fi
}

install_tracked() {
    # install_tracked SRC DST MODE
    local src=$1 dst=$2 mode=$3 tmp
    tmp=$(mktemp "$(dirname "$dst")/.cups-label-crop.XXXXXX")
    cat "$src" > "$tmp"
    chmod "$mode" "$tmp"
    chown root:root "$tmp"
    if [ -f "$dst" ] && cmp -s "$tmp" "$dst"; then
        rm -f "$tmp"; info "unchanged $dst"
    else
        mv -f "$tmp" "$dst"; info "installed $dst"
    fi
    M_FILE[$dst]=$(sha "$dst")
    manifest_save
}

mkdir_tracked "$STATE_DIR"
manifest_save

FAILED_STEP="python dependencies"
case "$DEP_MODE" in
    venv-new)
        mkdir_tracked "$PREFIX"
        say "creating venv $VENV"
        "$PY_SYS" -m venv "$VENV"
        touch "$VENV_MARK"
        M_VENV=$VENV; manifest_save
        "$VENV/bin/pip" install --disable-pip-version-check --no-cache-dir -q "$PIKEPDF_SPEC"
        chmod -R a+rX "$VENV"
        py_has_pikepdf "$INTERP" || { echo "pikepdf in the venv is not usable by user $CUPS_USER" >&2; false; }
        ;;
    venv-existing)
        # A venv we kept at an earlier --uninstall: $PREFIX is ours (preflight checked it holds only our files)
        M_VENV=$VENV
        in_list "$PREFIX" "${M_DIRS[@]}" || M_DIRS+=("$PREFIX")
        manifest_save ;;
    pkg)
        say "installing with $PKG_MGR: ${PKG_LIST[*]}"
        case "$PKG_MGR" in
            apt-get) DEBIAN_FRONTEND=noninteractive apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${PKG_LIST[@]}" ;;
            dnf) dnf install -y "${PKG_LIST[@]}" ;;
            zypper) zypper --non-interactive install "${PKG_LIST[@]}" ;;
            pacman) pacman -S --needed --noconfirm "${PKG_LIST[@]}" ;;
            apk) apk add "${PKG_LIST[@]}" ;;
        esac
        for p in "${PKG_LIST[@]}"; do in_list "$PKG_MGR $p" "${M_PKGS[@]}" || M_PKGS+=("$PKG_MGR $p"); done
        manifest_save
        py_has_pikepdf "$INTERP" || { echo "pikepdf still not importable after installing packages" >&2; false; }
        ;;
esac

FAILED_STEP="files"
mkdir_tracked "$PREFIX"
mkdir_tracked "$PREFIX/test"
mkdir_tracked "$CONF_DIR"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
{ echo "#!$INTERP"; tail -n +2 "$SRC_FILTER"; } > "$STAGE/label-crop"
W_PT=$(awk -v v="$W_IN" 'BEGIN{printf "%d", v*72+0.5}')
H_PT=$(awk -v v="$H_IN" 'BEGIN{printf "%d", v*72+0.5}')
cat > "$STAGE/label-crop.conf" <<CONF
# cups-label-crop-file: label-crop.conf
# Written by the cups-label-crop add-on installer. Re-run the installer to change it.
TARGET_PRINTER=$TARGET
CROP_QUEUE_NAME=$NAME
LABEL_WIDTH_IN=$W_IN
LABEL_HEIGHT_IN=$H_IN
LABEL_WIDTH_PT=$W_PT
LABEL_HEIGHT_PT=$H_PT
PADDING_PT=$PADDING
ROTATE_MODE=$ROTATE
TARGET_MEDIA=
CROP_BIN=$DST_FILTER
CONF
install_tracked "$STAGE/label-crop" "$DST_FILTER" 0755
install_tracked "$SRC_BACKEND" "$DST_BACKEND" 0755
install_tracked "$SRC_PPD" "$DST_PPD" 0644
install_tracked "$SRC_FIXTURE" "$DST_FIXTURE" 0644
install_tracked "$STAGE/label-crop.conf" "$CONF_FILE" 0644

FAILED_STEP="queue"
in_list "$NAME" "${M_QUEUES[@]}" || { M_QUEUES+=("$NAME"); manifest_save; }
if ! out=$(lpadmin -p "$NAME" -P "$DST_PPD" -v "labelcrop:$TARGET" -D "$DISPLAY_NAME" \
        -o printer-is-shared=true -o printer-error-policy=retry-job -o "PageSize=$SHEET" -E 2>&1); then
    echo "$out" >&2
    false
fi
# CUPS 2.4 prints "Printer drivers are deprecated" for any PPD queue; harmless.
echo "$out" | grep -v -i 'deprecated' || true
queue_exists "$NAME" || { echo "lpadmin did not create $NAME" >&2; false; }
cupsaccept "$NAME" || true
cupsenable "$NAME" || true
say "queue $NAME (\"$DISPLAY_NAME\") -> $TARGET"
for q in "${OLD_QUEUES[@]}"; do
    if queue_exists "$q"; then
        case "$(queue_uri "$q")" in labelcrop:*) lpadmin -x "$q" && say "removed old crop queue $q" ;; esac
    fi
    keep=(); for x in "${M_QUEUES[@]}"; do [ "$x" != "$q" ] && keep+=("$x"); done; M_QUEUES=("${keep[@]}")
    manifest_save
done

if [ "$SHARING_ACTION" = enable ]; then
    FAILED_STEP="sharing"
    in_list "share_printers=0" "${M_SETTINGS[@]}" || M_SETTINGS+=("share_printers=0")
    M_META[cupsctl_before]=$BACKUP/cupsctl.txt
    manifest_save
    cupsctl --share-printers
    wait_cupsd
    say "printer sharing turned on (recorded for --uninstall)"
fi
trap - ERR

# ================================================================== verify
FAILED_STEP="verify"
PROBLEMS=0
snapshot_queues > "$BACKUP/queues-after.txt"
if diff -u "$BACKUP/queues-before.txt" "$BACKUP/queues-after.txt" > "$BACKUP/queues.diff"; then
    say "verified: all $(grep -c '^== ' "$BACKUP/queues-after.txt" || true) other queue(s) unchanged (URI, PPD checksum, options)"
else
    PROBLEMS=1
    loud "Your other CUPS queues look DIFFERENT after the install. cups-label-crop did not intend this." \
         "Diff ($BACKUP/queues.diff):" "$(cat "$BACKUP/queues.diff")" \
         "To undo the add-on:   sudo bash $SELF_DIR/install.sh --uninstall --yes" \
         "To restore all of CUPS: see $BACKUP/RESTORE.txt"
fi

TESTDIR=$(mktemp -d)
chmod 777 "$TESTDIR"
if run_as_cups_user "$DST_FILTER" "$DST_FIXTURE" "$TESTDIR/out.pdf" > "$TESTDIR/log" 2>&1 \
   && run_as_cups_user "$INTERP" -c '
import sys, pikepdf
pdf = pikepdf.Pdf.open(sys.argv[1])
p = pdf.pages[0].mediabox
w, h = float(p[2]) - float(p[0]), float(p[3]) - float(p[1])
sys.exit(0 if abs(w - float(sys.argv[2])) < 0.6 and abs(h - float(sys.argv[3])) < 0.6 else 1)' "$TESTDIR/out.pdf" "$(awk -v v="$W_IN" 'BEGIN{print v*72}')" "$(awk -v v="$H_IN" 'BEGIN{print v*72}')"; then
    say "verified: test crop of the sample sheet as user $CUPS_USER gave a ${W_IN}x${H_IN} in page"
else
    if [ "$W_IN" = 4 ] && [ "$H_IN" = 6 ]; then
        PROBLEMS=1
        loud "Test crop FAILED (filter could not process the bundled sample)." "$(cat "$TESTDIR/log")"
    else
        say "note: the bundled 4x6 sample does not match your ${W_IN}x${H_IN} size, so the self-test is informational only"
    fi
fi
rm -rf "$TESTDIR"

echo
if [ "$PROBLEMS" = 0 ]; then
    say "done. Print A4/Letter label sheets to \"$DISPLAY_NAME\"; cropped labels go to $TARGET."
else
    say "finished WITH PROBLEMS (see above)."
fi
say "manifest: $MANIFEST   backup: $BACKUP"
say "uninstall: sudo bash $SELF_DIR/install.sh --uninstall"
[ "$PROBLEMS" = 0 ]
