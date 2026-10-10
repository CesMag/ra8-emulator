#!/bin/bash -p
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Brighton Sikarskie
#
# modules_corpus.sh -- run every ThreadX Modules image whose module manager
# sits on the M85 (CPU0) through the example table and diff the rows
# against tools/modules_expected.md (RA8EMU-152). An image is a
# txm_*_m85.elf as ra8-firmware's `zig build arm` leaves it in zig-out/arm;
# the module manager images on CPU1 are pairs and live in
# dualcore_corpus.sh. txm_sd_hello_m85 reads txm_hello_m33.ra8app off the
# SDHI card, so the script puts DIR's copy in txm_sd_hello_m85.sd, the card
# directory the example table hands it (RA8EMU-158).
#
#   tools/modules_corpus.sh EMULATOR DIR
#
# Extra flags for `zig build` (an optimize mode, for one) come from
# ZIG_BUILD_ARGS. Exits 1 on any difference: an image that stopped passing,
# a console line that changed, or an expected image missing from DIR.
# Update the expected file in the same PR as a change that means to move
# a row.

set -euo pipefail

if [ $# -ne 2 ]; then
    echo "usage: $0 EMULATOR DIR" >&2
    exit 2
fi
emulator=$(realpath "$1")
dir=$2
here=$(cd "$(dirname "$0")" && pwd)
expected=$here/modules_expected.md

images=$(mktemp -d)
trap 'rm -rf "$images"' EXIT
for image in "$dir"/txm_*_m85.elf; do
    [ -e "$image" ] || continue
    cp "$image" "$images/"
done
if [ -e "$dir/txm_hello_m33.ra8app" ]; then
    mkdir "$images/txm_sd_hello_m85.sd"
    cp "$dir/txm_hello_m33.ra8app" "$images/txm_sd_hello_m85.sd/"
fi

# shellcheck disable=SC2086
actual=$(cd "$here/.." && zig build examples ${ZIG_BUILD_ARGS:-} -- "$emulator" "$images")
diff -u "$expected" <(printf '%s\n' "$actual")
