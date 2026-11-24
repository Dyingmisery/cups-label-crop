#!/bin/sh
# Regenerate addon/SHA256SUMS: the checksums of every file the add-on
# installer reads. CI fails if this file is out of date.
set -eu
cd "$(dirname "$0")/.."
sha256sum addon/install.sh src/label-crop src/labelcrop src/label-crop.ppd \
    tests/fixtures/mock-vinted-a4-landscape.pdf > addon/SHA256SUMS
echo "wrote addon/SHA256SUMS"
