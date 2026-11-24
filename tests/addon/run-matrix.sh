#!/bin/bash
# Run the add-on safety tests in disposable containers.
#   DOCKER="sudo docker" bash tests/addon/run-matrix.sh [scenario...]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
DOCKER=${DOCKER:-docker}
OUT=${OUT:-/tmp/addon-matrix}
mkdir -p "$OUT"
# name | image | platform | setup packages | extra installer flags | how the container is started
SCENARIOS=(
  "trixie-system|debian:trixie-slim|linux/amd64|cups cups-client python3 python3-pikepdf poppler-utils||sleep"
  "bookworm-venv|debian:bookworm-slim|linux/amd64|cups cups-client python3 python3-venv ca-certificates||sleep"
  "bookworm-deps|debian:bookworm-slim|linux/amd64|cups cups-client|--install-deps|sleep"
  "noble-deps|ubuntu:24.04|linux/amd64|cups cups-client|--install-deps|sleep"
  "jammy-venv|ubuntu:22.04|linux/amd64|cups cups-client python3 python3-venv ca-certificates||sleep"
  "anujdatar|anujdatar/cups:latest|linux/amd64||--install-deps|image"
  "olbat|olbat/cupsd:latest|linux/amd64||--install-deps|image"
  "fedora-deps|fedora:latest|linux/amd64|cups cups-client util-linux procps-ng diffutils|--install-deps|sleep"
  "trixie-arm64|debian:trixie-slim|linux/arm64|cups cups-client python3 python3-pikepdf poppler-utils||sleep"
)
want=("$@")
total_fail=0
for s in "${SCENARIOS[@]}"; do
    IFS='|' read -r name image plat pkgs flags start <<<"$s"
    if [ ${#want[@]} -gt 0 ] && [[ ! " ${want[*]} " =~ \ $name\  ]]; then continue; fi
    c="addon-test-$name"
    $DOCKER rm -f "$c" >/dev/null 2>&1
    if [ "$start" = sleep ]; then
        $DOCKER run -d --name "$c" --platform "$plat" -v "$REPO:/src:ro" --entrypoint sleep "$image" infinity >/dev/null || { echo "$name: could not start"; continue; }
    else
        $DOCKER run -d --name "$c" --platform "$plat" -v "$REPO:/src:ro" -e CUPSADMIN=admin -e CUPSPASSWORD=admin "$image" >/dev/null || { echo "$name: could not start"; continue; }
        sleep 8
    fi
    $DOCKER exec -e SETUP_PKGS="$pkgs" -e EXTRA_FLAGS="$flags" "$c" bash /src/tests/addon/in-container.sh > "$OUT/$name.log" 2>&1
    rc=$?
    $DOCKER exec "$c" sh -c 'tar -C /tmp -cf - addon-test 2>/dev/null' > "$OUT/$name-logs.tar" 2>/dev/null
    printf '%-14s rc=%s  %s\n' "$name" "$rc" "$(tail -n 1 "$OUT/$name.log")"
    [ "$rc" = 0 ] || total_fail=$((total_fail + 1))
    $DOCKER rm -f "$c" >/dev/null 2>&1
done
exit $total_fail
