#!/bin/bash
# Unit tests for the label-crop filter. Needs python3-pikepdf and poppler-utils.
#   bash tests/run-tests.sh            (uses src/label-crop)
#   CROP=/usr/lib/cups/filter/label-crop bash tests/run-tests.sh   (inside the image)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CROP="${CROP:-$HERE/../src/label-crop}"
FIX="$HERE/fixtures"
OUT="${OUT:-$HERE/out}"
mkdir -p "$OUT"
# Do not let a container config file change the expected results
export LABEL_CROP_CONFIG=/nonexistent
unset LABEL_WIDTH_IN LABEL_HEIGHT_IN PADDING_PT ROTATE_MODE
PASS=0; FAIL=0

ok()   { PASS=$((PASS + 1)); }
bad()  { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

# expect_ok NAME INPUT W_PT H_PT CORNER [label-crop flags...]
expect_ok() {
    local name="$1" in="$2" w="$3" h="$4" corner="$5"; shift 5
    local out="$OUT/$name.pdf" args=()
    [ "$corner" != "-" ] && args=(--dark-corner "$corner")
    if python3 "$CROP" "$@" "$FIX/$in" "$out" 2>"$OUT/$name.log" && python3 "$HERE/check.py" "$out" "$w" "$h" "${args[@]}"; then
        ok
    else
        bad "$name ($in $*)"; sed 's/^/    /' "$OUT/$name.log"
    fi
}

expect_reject() {
    local name="$1" in="$2"; shift 2
    if python3 "$CROP" "$@" "$FIX/$in" "$OUT/$name.pdf" 2>"$OUT/$name.log"; then
        bad "$name: expected $in to be rejected"
    else
        echo "ok   $name: rejected ($(tail -n 1 "$OUT/$name.log"))"; ok
    fi
}

echo "== prototype fixtures (4x6 default)"
expect_ok inpost-landscape  mock-vinted-a4-landscape.pdf 288 432 tr
expect_ok evri-portrait     mock-vinted-a4-portrait.pdf  288 432 tr
expect_ok ink-fallback      mock-vinted-a4-ink.pdf       288 432 -
expect_ok already-4x6       mock-already-4x6.pdf         288 432 -
expect_reject no-label      mock-a4-no-label.pdf

echo "== generic layouts"
expect_ok us-letter         mock-generic-letter.pdf        288 432 tr
expect_ok a4-100x150mm      mock-generic-a4-100x150mm.pdf  288 432 tr

echo "== settings"
expect_ok size-4x4          mock-generic-a4-4x4.pdf      288 288 tr --width-in 4 --height-in 4
expect_ok size-100x150-in   mock-vinted-a4-portrait.pdf  283 425 tr --width-in 3.937 --height-in 5.906
expect_ok landscape-out     mock-vinted-a4-portrait.pdf  432 288 tl --width-in 6 --height-in 4
expect_ok rotate-0-forced   mock-vinted-a4-landscape.pdf 288 432 - --rotate 0
expect_ok rotate-90-flipped mock-vinted-a4-landscape.pdf 288 432 bl --rotate 90
expect_ok rotate-180        mock-vinted-a4-portrait.pdf  288 432 bl --rotate 180
expect_ok padding-0         mock-vinted-a4-portrait.pdf  288 432 tr --padding-pt 0
expect_reject bad-rotate    mock-vinted-a4-portrait.pdf  --rotate 45
expect_reject 4x4-label-in-4x6-mode mock-generic-a4-4x4.pdf

echo "== environment and config file"
if LABEL_WIDTH_IN=4 LABEL_HEIGHT_IN=4 python3 "$CROP" "$FIX/mock-generic-a4-4x4.pdf" "$OUT/env.pdf" 2>/dev/null \
   && python3 "$HERE/check.py" "$OUT/env.pdf" 288 288; then ok; else bad "env LABEL_*_IN"; fi
printf 'LABEL_WIDTH_IN=4\nLABEL_HEIGHT_IN=4\n' > "$OUT/test.conf"
if LABEL_CROP_CONFIG="$OUT/test.conf" python3 "$CROP" "$FIX/mock-generic-a4-4x4.pdf" "$OUT/conf.pdf" 2>/dev/null \
   && python3 "$HERE/check.py" "$OUT/conf.pdf" 288 288; then ok; else bad "config file"; fi

echo "== --if-needed passthrough"
if python3 "$CROP" --if-needed "$OUT/evri-portrait.pdf" "$OUT/passthrough.pdf" 2>/dev/null \
   && cmp -s "$OUT/evri-portrait.pdf" "$OUT/passthrough.pdf"; then echo "ok   already-cropped job copied unchanged"; ok; else bad "--if-needed"; fi

echo "== CUPS filter mode (job-id user title copies options file)"
if python3 "$CROP" 1 tester title 1 "" "$FIX/mock-vinted-a4-landscape.pdf" > "$OUT/filter-file.pdf" 2>"$OUT/filter.log" \
   && python3 "$HERE/check.py" "$OUT/filter-file.pdf" 288 432 --dark-corner tr; then ok; else bad "filter mode (file)"; cat "$OUT/filter.log"; fi
if python3 "$CROP" 1 tester title 1 "" < "$FIX/mock-vinted-a4-landscape.pdf" > "$OUT/filter-stdin.pdf" 2>>"$OUT/filter.log" \
   && python3 "$HERE/check.py" "$OUT/filter-stdin.pdf" 288 432 --dark-corner tr; then ok; else bad "filter mode (stdin)"; fi
if printf 'UNIRAST\0junk' | python3 "$CROP" 1 tester title 1 "" > /dev/null 2>"$OUT/urf.log"; then
    bad "URF raster should be rejected"
else echo "ok   urf raster rejected with a clear message"; ok; fi

echo "Passed $PASS  Failed $FAIL"
[ "$FAIL" -eq 0 ]
