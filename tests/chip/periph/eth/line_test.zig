//! Tests for src/chip/periph/eth/line.zig.
const std = @import("std");
const ra8 = @import("ra8");
const regs = ra8.chip.periph.eth_regs;
const line = ra8.chip.periph.eth_line;

fn frame(op: regs.Op, data: u16) u32 {
    return regs.rmac.psme |
        (@as(u32, 1) << regs.rmac.pra_shift) |
        (@as(u32, @backingInt(op)) << regs.rmac.pop_shift) |
        (@as(u32, data) << 16);
}

test "a read on a bus with no PHY clears PSME and finds the idle level" {
    const out = line.unanswered(frame(.read, 0));
    try std.testing.expectEqual(@as(u32, 0), out & regs.rmac.psme);
    try std.testing.expectEqual(line.idle_data, regs.dataOf(out));
}

test "a write on a bus with no PHY clears PSME and keeps its data" {
    const out = line.unanswered(frame(.write, 0x0041));
    try std.testing.expectEqual(@as(u32, 0), out & regs.rmac.psme);
    try std.testing.expectEqual(@as(u16, 0x0041), regs.dataOf(out));
}
