//! The memory geometry line for a run on a non-default part.
//!
//! `--part ra8p1` used to change only whether the NPU window answers, and a
//! run said nothing about which part it modelled. This line names the part
//! and the geometry src/chip/core/part/map.zig cites for it. It prints only off
//! the default part, so an RA8D2 run's report stays byte identical to the
//! one every corpus expectation was recorded against.
const std = @import("std");
const part = @import("ra8_chip").core.part;
const Writer = @import("../report.zig").Writer;

const kib: u32 = 1024;

/// The part line, written into `buf`.
pub fn line(buf: []u8, which: part.Part) ![]const u8 {
    const geometry = part.map.of(which);
    return std.fmt.bufPrint(buf, "PART: {s} MRAM {d} KB @0x{X:0>8}, SRAM {d} KB @0x{X:0>8}, " ++
        "CPU0 TCM {d} KB + cache {d} KB, CPU1 TCM {d} KB + cache {d} KB ({s})\n", .{
        which.label(),
        geometry.mram_bytes / kib,
        geometry.mram_base,
        geometry.sram_bytes / kib,
        geometry.sram_base,
        geometry.cpu0TcmBytes() / kib,
        2 * geometry.cpu0_cache_bank_bytes / kib,
        geometry.cpu1TcmBytes() / kib,
        2 * geometry.cpu1_cache_bank_bytes / kib,
        geometry.source,
    });
}

/// Whether a run on `which` prints the part line at all.
pub fn shown(which: part.Part) bool {
    return which != .ra8d2;
}

/// Print the part line for `which`, when it is not the default part.
pub fn print(out: Writer, which: part.Part) !void {
    if (!shown(which)) return;
    var buf: [256]u8 = undefined;
    try out.writeAll(try line(&buf, which));
}
