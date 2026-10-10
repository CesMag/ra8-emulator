const std = @import("std");
const testing = std.testing;

const sync = @import("ra8").chip.periph.gpt_sync;
const win = @import("ra8").chip.periph.gpt_window;
const clk = @import("ra8").chip.periph.gpt_clock;

/// Just enough of a channel for the dispatch to act on: the control byte it
/// sets CST in and the counter it zeroes.
const Stub = struct {
    cr: u32 = 0,
    cnt: u32 = 0,
};

fn bank() [14]Stub {
    return @as([14]Stub, @splat(.{}));
}

fn running(channel: Stub) bool {
    return channel.cr & clk.field.cst != 0;
}

test "each of the three offsets names its own action" {
    try testing.expectEqual(sync.Action.start, sync.which(win.off.gtstr).?);
    try testing.expectEqual(sync.Action.stop, sync.which(win.off.gtstp).?);
    try testing.expectEqual(sync.Action.clear, sync.which(win.off.gtclr).?);
}

test "an offset outside the three belongs to none of them" {
    try testing.expect(sync.which(win.off.gtcr) == null);
    try testing.expect(sync.which(win.off.gtcnt) == null);
}

test "a byte anywhere inside a register still names that register" {
    try testing.expectEqual(sync.Action.start, sync.which(win.off.gtstr + 3).?);
    try testing.expectEqual(sync.Action.stop, sync.which(win.off.gtstp + 1).?);
}

test "a whole-word store carries every bit it was given" {
    try testing.expectEqual(@as(u32, 0x0000_0007), sync.carried(0, 4, 0x0000_0007));
}

test "a byte store one in from the base names the upper channels" {
    try testing.expectEqual(@as(u32, 0x0000_0100), sync.carried(1, 1, 0x01));
    try testing.expectEqual(@as(u32, 0x0000_0000), sync.carried(1, 1, 0x00));
}

test "a narrow store carries nothing from the lanes it does not name" {
    try testing.expectEqual(@as(u32, 0x0000_0001), sync.carried(0, 1, 0xFFFF_FF01));
}

test "one store starts every channel it names" {
    var state = sync.Sync{};
    var channels = bank();
    sync.dispatch(&state, .start, 0b0111, 0, &channels);
    try testing.expect(running(channels[0]));
    try testing.expect(running(channels[1]));
    try testing.expect(running(channels[2]));
    try testing.expect(!running(channels[3]));
    try testing.expectEqual(@as(u32, 3), state.acted);
    try testing.expectEqual(@as(u32, 1), state.together);
}

test "a stop clears CST and a clear zeroes the count" {
    var state = sync.Sync{};
    var channels = bank();
    channels[2].cr = clk.field.cst;
    channels[2].cnt = 0x1234;
    sync.dispatch(&state, .clear, 0b0100, 2, &channels);
    try testing.expectEqual(@as(u32, 0), channels[2].cnt);
    try testing.expect(running(channels[2]));
    sync.dispatch(&state, .stop, 0b0100, 2, &channels);
    try testing.expect(!running(channels[2]));
}

test "a bit naming a channel this bank does not carry is counted" {
    var state = sync.Sync{};
    var channels = bank();
    sync.dispatch(&state, .start, @as(u32, 1) << 20, 0, &channels);
    try testing.expectEqual(@as(u32, 0), state.acted);
    try testing.expectEqual(@as(u32, 1), state.absent);
}

test "a store naming its own window is not stray" {
    var state = sync.Sync{};
    var channels = bank();
    sync.dispatch(&state, .start, 0b0001, 0, &channels);
    try testing.expectEqual(@as(u32, 0), state.stray);
}

test "a bank-wide start through channel 0 is not stray" {
    var state = sync.Sync{};
    var channels = bank();
    sync.dispatch(&state, .start, 0b0111, 0, &channels);
    try testing.expectEqual(@as(u32, 0), state.stray);
}

test "the deinit shape, CSTOP0 through another window, is stray" {
    var state = sync.Sync{};
    var channels = bank();
    channels[0].cr = clk.field.cst;
    sync.dispatch(&state, .stop, 0b0001, 5, &channels);
    try testing.expectEqual(@as(u32, 1), state.stray);
    // It really did stop channel 0: the count is what happened, not a refusal.
    try testing.expect(!running(channels[0]));
}

test "a store naming nobody at all is not stray" {
    var state = sync.Sync{};
    var channels = bank();
    sync.dispatch(&state, .stop, 0, 5, &channels);
    try testing.expectEqual(@as(u32, 0), state.stray);
    try testing.expect(state.quiet());
}

test "a bank that saw nothing is quiet" {
    const state = sync.Sync{};
    try testing.expect(state.quiet());
}
