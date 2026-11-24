#!/bin/bash
# End-to-end test of the cups-label-crop image: start it, print mock sheets
# through the crop queue into a capture "printer", restart with the same
# /config, install a dropped-in driver .deb, and check AirPrint advertising.
#   IMAGE=cups-label-crop:dev bash tests/container-test.sh
# Uses host networking (port 631 must be free). SKIP_MDNS=1 skips the Avahi check.
# ok() and bad() always succeed, so "test && ok || bad" is safe here.
# shellcheck disable=SC2015
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGE=${IMAGE:-cups-label-crop:dev}
NAME=clc-test
CFG=$(mktemp -d /tmp/clc-config.XXXXXX)
chmod 755 "$CFG"   # like /mnt/user/appdata: the lp user must be able to traverse it
DOCKER=${DOCKER:-docker}
PASS=0; FAIL=0
ok()  { echo "ok   $*"; PASS=$((PASS + 1)); }
bad() { echo "FAIL $*"; FAIL=$((FAIL + 1)); }
dx()  { $DOCKER exec "$NAME" "$@"; }

cleanup() { $DOCKER rm -f "$NAME" >/dev/null 2>&1; sudo rm -rf "$CFG" 2>/dev/null || rm -rf "$CFG"; }
trap cleanup EXIT

start() {
    $DOCKER stop -t 10 "$NAME" >/dev/null 2>&1
    $DOCKER rm -f "$NAME" >/dev/null 2>&1
    $DOCKER run -d --name "$NAME" --network host \
        -e CUPSADMIN=tester -e CUPSPASSWORD=s3cret -e TZ=Europe/London \
        -e TARGET_PRINTER="${TARGET:-Test_Target}" "$@" \
        -v "$CFG:/config" -v "$HERE:/tests:ro" "$IMAGE" >/dev/null
    for _ in $(seq 1 60); do
        $DOCKER logs "$NAME" 2>&1 | grep -q "ready: web UI" && return 0
        sleep 0.5
    done
    echo "container did not become ready:"; $DOCKER logs "$NAME"; return 1
}

add_capture_target() {
    dx install -m 0755 /tests/capture-backend /usr/lib/cups/backend/capture
    dx mkdir -p /config/capture && dx chmod 777 /config/capture
    dx lpadmin -p "$1" -v capture:/ -m raw -E 2>/dev/null
}

wait_capture() { # wait_capture N -> waits until N files captured
    for _ in $(seq 1 60); do
        [ "$(dx sh -c 'ls /config/capture/*.pdf 2>/dev/null | wc -l')" -ge "$1" ] && return 0
        sleep 0.5
    done
    return 1
}

echo "== start"
start || exit 1
$DOCKER logs "$NAME" 2>&1 | sed 's/^/    /'
dx lpstat -p Label_Crop >/dev/null 2>&1 && ok "crop queue Label_Crop created" || bad "crop queue missing"
dx lpstat -l -p Label_Crop | grep -q "Label Crop" && ok "display name 'Label Crop'" || bad "display name"
dx lpstat -v Label_Crop | grep -q "labelcrop:Test_Target" && ok "device URI labelcrop:Test_Target" || bad "device URI"
dx grep -q "TARGET_PRINTER=Test_Target" /etc/cups-label-crop/label-crop.conf && ok "filter config written" || bad "filter config"
[ -f "$CFG/cups/cupsd.conf" ] && [ -d "$CFG/cups/ppd" ] && ok "cupsd.conf and ppd/ live in /config/cups" || bad "config not in /config/cups"
[ "$(dx date +%Z)" = "GMT" ] || [ "$(dx date +%Z)" = "BST" ] && ok "TZ applied ($(dx date +%Z))" || bad "TZ"

echo "== web UI and admin auth"
code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:631/printers/)
[ "$code" = 200 ] && ok "web UI /printers/ -> 200" || bad "web UI -> $code"
code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:631/admin)
[ "$code" = 401 ] && ok "/admin without login -> 401" || bad "/admin unauth -> $code"
code=$(curl -s -o /dev/null -w '%{http_code}' -u tester:s3cret http://127.0.0.1:631/admin)
[ "$code" = 200 ] && ok "/admin as CUPSADMIN -> 200" || bad "/admin auth -> $code"

echo "== job before the target printer exists"
dx lp -d Label_Crop -t early /tests/fixtures/mock-vinted-a4-landscape.pdf >/dev/null
sleep 4
if dx lpstat -o Label_Crop | grep -q Label_Crop; then ok "job waits (retry) while target is missing"; else bad "early job vanished"; fi
dx lpstat -l -p Label_Crop | grep -i -m1 "target queue" | sed 's/^/    /'

echo "== print through the crop queue"
add_capture_target Test_Target
dx cancel -a Label_Crop
for f in mock-vinted-a4-landscape mock-vinted-a4-portrait mock-vinted-a4-ink mock-generic-letter; do
    dx lp -d Label_Crop -t "$f" "/tests/fixtures/$f.pdf" >/dev/null
done
if wait_capture 4; then
    for f in $(dx sh -c 'ls /config/capture/*.pdf'); do
        if dx python3 /tests/check.py "$f" 288 432 >/dev/null; then ok "forwarded $(basename "$f") is 288x432 pt"; else bad "$f wrong size"; dx python3 /tests/check.py "$f" 288 432; fi
    done
else
    bad "jobs did not reach the target"; dx lpstat -o; dx tail -n 40 /var/log/cups/error_log
fi
dx lp -d Label_Crop -t nolabel /tests/fixtures/mock-a4-no-label.pdf >/dev/null
sleep 4
n=$(dx sh -c 'ls /config/capture/*.pdf | wc -l')
[ "$n" -eq 4 ] && ok "sheet without a label is not forwarded" || bad "no-label sheet was forwarded"
dx cancel -a Label_Crop 2>/dev/null; dx cupsenable Label_Crop 2>/dev/null

echo "== restart with the same /config (image update simulation)"
start || exit 1
sudo test -f "$CFG/cups/printers.conf" 2>/dev/null || test -f "$CFG/cups/printers.conf" && ok "printers.conf stored in /config/cups" || bad "printers.conf not in /config"
dx lpstat -p Test_Target >/dev/null 2>&1 && ok "user-added printer survived recreate" || bad "Test_Target lost"
dx lpstat -p Label_Crop >/dev/null 2>&1 && ok "crop queue present after recreate" || bad "crop queue lost"

echo "== driver drop-in (/config/drivers/*.deb) and PRINTER_URI auto-create"
PKG=$(mktemp -d)
mkdir -p "$PKG/DEBIAN" "$PKG/usr/share/cups/model"
printf 'Package: clc-dummy-driver\nVersion: 1.0\nArchitecture: all\nMaintainer: test <t@example.invalid>\nDescription: dummy\n' > "$PKG/DEBIAN/control"
cp /dev/null "$PKG/usr/share/cups/model/clc-dummy.txt"
dpkg-deb --build "$PKG" /tmp/clc-dummy-driver.deb >/dev/null 2>&1 || $DOCKER run --rm -v "$PKG:/p" -v /tmp:/o --entrypoint dpkg-deb "$IMAGE" --build /p /o/clc-dummy-driver.deb >/dev/null
rm -rf "$PKG"
sudo mkdir -p "$CFG/drivers" 2>/dev/null || mkdir -p "$CFG/drivers"
sudo cp /tmp/clc-dummy-driver.deb "$CFG/drivers/" 2>/dev/null || cp /tmp/clc-dummy-driver.deb "$CFG/drivers/"
# install.sh hook: vendor installers that are not .deb (here: the capture backend)
printf '#!/bin/sh\ninstall -m 0755 /tests/capture-backend /usr/lib/cups/backend/capture\n' > /tmp/clc-install.sh
sudo cp /tmp/clc-install.sh "$CFG/drivers/install.sh" 2>/dev/null || cp /tmp/clc-install.sh "$CFG/drivers/install.sh"
TARGET=Auto_Target start -e PRINTER_URI=capture:/ -e PRINTER_PPD=raw || exit 1
dx dpkg -s clc-dummy-driver >/dev/null 2>&1 && ok "driver .deb installed at startup" || { bad "driver not installed"; $DOCKER logs "$NAME" | tail; }
dx test -x /usr/lib/cups/backend/capture && ok "/config/drivers/install.sh ran at startup" || bad "install.sh hook"
dx lpstat -v Auto_Target 2>/dev/null | grep -q capture:/ && ok "PRINTER_URI created Auto_Target" || { bad "PRINTER_URI auto-create"; $DOCKER logs "$NAME" | tail; }
dx lpstat -v Label_Crop | grep -q "labelcrop:Auto_Target" && ok "crop queue retargeted to Auto_Target" || bad "retarget"
before=$(dx sh -c 'ls /config/capture/*.pdf | wc -l')
dx lp -d Label_Crop /tests/fixtures/mock-vinted-a4-portrait.pdf >/dev/null
wait_capture $((before + 1)) && ok "job forwarded to the auto-created printer" || bad "auto target job"

if [ "${SKIP_MDNS:-0}" != 1 ]; then
    echo "== AirPrint / mDNS advertisement"
    sleep 3
    out=$(dx avahi-browse -rtp _ipp._tcp 2>/dev/null | grep -i 'Label\\032Crop' || true)
    if [ -n "$out" ]; then
        ok "Label Crop advertised as _ipp._tcp"
        echo "$out" | grep -q 'URF=' && ok "TXT record has URF (AirPrint)" || bad "no URF in TXT"
        dx avahi-browse -tp _universal._sub._ipp._tcp 2>/dev/null | grep -qi 'Label\\032Crop' && ok "advertised in _universal._sub._ipp._tcp (iOS)" || bad "not in _universal subtype"
    else
        bad "Label Crop not seen by avahi-browse"
    fi
fi

echo "== renaming the crop queue (CROP_QUEUE_NAME)"
TARGET=Auto_Target start -e CROP_QUEUE_NAME=Vinted_Label -e CROP_QUEUE_DISPLAY_NAME="Vinted Label" || exit 1
dx lpstat -p Vinted_Label >/dev/null 2>&1 && ok "new crop queue Vinted_Label created" || bad "Vinted_Label missing"
dx lpstat -p Label_Crop >/dev/null 2>&1 && bad "old Label_Crop queue still present" || ok "old Label_Crop queue removed"
dx lpstat -p Auto_Target >/dev/null 2>&1 && ok "real printer untouched by the rename" || bad "Auto_Target removed"

echo "== image unit tests inside the container"
if dx bash -c 'CROP=/usr/lib/cups/filter/label-crop OUT=/tmp/t bash /tests/run-tests.sh' > /tmp/clc-unit.log 2>&1; then
    ok "tests/run-tests.sh inside image: $(tail -n 1 /tmp/clc-unit.log)"
else bad "unit tests inside image"; cat /tmp/clc-unit.log; fi

echo "Passed $PASS  Failed $FAIL"
[ "$FAIL" -eq 0 ]
