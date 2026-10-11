//! Covers src/chip/core/second/state.zig: CPU1's run state with no engine.
const std = @import("std");
const ra8 = @import("ra8");
const State = ra8.chip.core.second.core.State;

test "a state with no dividers gives CPU1 the whole round" {
    const state: State = .{};
    try std.testing.expectEqual(ra8.chip.core.second.core.rate.turn(1000, 0), state.turn(1000));
}

test "a state with no board is never held in reset" {
    var state: State = .{};
    var store = try ra8.chip.core.cpu.memory.store.Store.init(null);
    defer store.deinit();
    try std.testing.expect(!state.heldInReset(.{ .store = &store }));
    try std.testing.expectEqual(@as(u32, 0), state.restarts);
}
