#!/bin/sh
# RA8EMU-75 slice 5c: run usb_printer_vendor with --usbip 0, wait for the
# export line, then attach it with tools/usbip_attach.zig the way usbip
# does: list, import, read the device descriptor, loop 64 bytes through the
# vendor interface. Exit 0 on a pass, 1 on a failure, 77 when the ELF or
# zig is missing.
# usage: tools/usbip_e2e.sh EMULATOR ELF [MS [TOOL ARGS...]]
# TOOL ARGS go to usbip_attach: [VID:PID] [LEN] [--tty].
# ZIG_BUILD_FLAGS passes options to zig build (e.g. -Doptimize=ReleaseFast).
emu=$1
elf=$2
ms=${3:-5000}
shift 2
[ $# -gt 0 ] && shift
zig=${ZIG:-zig}
[ -f "$elf" ] || { echo "usbip_e2e: no $elf"; exit 77; }
command -v "$zig" >/dev/null 2>&1 || { echo "usbip_e2e: no zig"; exit 77; }
here=$(cd "$(dirname "$0")/.." && pwd)
log=$(mktemp)
cleanup() { [ -n "$pid" ] && kill "$pid" 2>/dev/null; rm -f "$log"; }
trap cleanup EXIT
"$emu" "$elf" --ms "$ms" --usbip 0 >/dev/null 2>"$log" &
pid=$!
port=""
while [ -z "$port" ]; do
    kill -0 "$pid" 2>/dev/null || { cat "$log"; echo "usbip_e2e: the emulator ended before exporting"; exit 1; }
    sleep 1
    port=$(sed -n 's/^usbip: exporting .* on 127\.0\.0\.1:\([0-9]*\)$/\1/p' "$log")
done
echo "usbip_e2e: exported on port $port"
(cd "$here" && "$zig" build usbip-attach $ZIG_BUILD_FLAGS -- "$port" "$@")
status=$?
grep '^usbip:' "$log"
[ "$status" -eq 0 ] && echo "usbip_e2e: passed" || echo "usbip_e2e: failed"
exit "$status"
