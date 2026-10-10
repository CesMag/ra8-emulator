#!/bin/bash -p
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Brighton Sikarskie
#
# dualcore_corpus.sh -- run every dual-core pair in a directory through the
# example table and diff the rows against tools/dualcore_expected.md
# (RA8EMU-37). A pair is foo.elf beside foo_cpu1.elf, as ra8-firmware's
# `zig build arm` leaves them in zig-out/arm.
#
#   tools/dualcore_corpus.sh EMULATOR DIR
#
# Both halves run on the Zig core (RA8EMU-140).
#
# Extra flags for `zig build` (an optimize mode, for one) come from
# ZIG_BUILD_ARGS. Exits 1 on any difference: a pair that stopped passing,
# a console line that changed, or an expected pair missing from DIR.
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
expected=$here/dualcore_expected.md

pairs=$(mktemp -d)
trap 'rm -rf "$pairs"' EXIT
for cpu1 in "$dir"/*_cpu1.elf; do
    [ -e "$cpu1" ] || continue
    cpu0=${cpu1%_cpu1.elf}.elf
    [ -e "$cpu0" ] || continue
    cp "$cpu0" "$cpu1" "$pairs/"
done

# shellcheck disable=SC2086
actual=$(cd "$here/.." && zig build examples ${ZIG_BUILD_ARGS:-} -- "$emulator" "$pairs")
diff -u "$expected" <(printf '%s\n' "$actual")
