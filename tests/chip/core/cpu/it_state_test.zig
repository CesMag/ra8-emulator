//! Covers src/chip/core/cpu/it_state.zig.
const std = @import("std");
const ra8 = @import("ra8");
const it_state = ra8.chip.core.cpu.it_state;

test "put and get round-trip through the split xPSR fields" {
    const xpsr: u32 = 0xF100_0000;
    for ([_]u8{ 0x00, 0x08, 0x1C, 0xA4, 0xFF, 0x03 }) |state| {
        const packed_xpsr = it_state.put(xpsr, state);
        try std.testing.expectEqual(state, it_state.get(packed_xpsr));
        try std.testing.expectEqual(xpsr, packed_xpsr & ~@as(u32, 0x0600_FC00));
    }
    try std.testing.expectEqual(@as(u32, 0x0600_0000), it_state.put(0, 0x03));
    try std.testing.expectEqual(@as(u32, 0x0000_FC00), it_state.put(0, 0xFC));
}

test "advance walks a four-instruction block to nothing" {
    // ITTET EQ: firstcond 0000, mask 0101 -> EQ, EQ, NE, EQ.
    var state: it_state.Itstate = 0x05;
    const want = [_]u4{ 0x0, 0x0, 0x1, 0x0 };
    for (want) |c| {
        try std.testing.expect(it_state.active(state));
        try std.testing.expectEqual(c, it_state.condition(state));
        state = it_state.advance(state);
    }
    try std.testing.expect(!it_state.active(state));
    try std.testing.expectEqual(@as(u8, 0), state);
}

test "a single IT governs one instruction" {
    const state: it_state.Itstate = 0x18; // IT NE
    try std.testing.expect(it_state.active(state));
    try std.testing.expectEqual(@as(u4, 1), it_state.condition(state));
    try std.testing.expectEqual(@as(u8, 0), it_state.advance(state));
}
