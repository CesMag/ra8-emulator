//! Tests for src/chip/core/idle.zig.
//!
//! The seam is exercised against a fake core rather than a live engine: the
//! question it answers is "did the machine come back to the state it left",
//! and a fake that walks a scripted list of states asks that precisely,
//! including the cases a real image would take hours to reach.
const std = @import("std");
const ra8 = @import("ra8");
const idle = ra8.chip.core.idle;
const fault = ra8.chip.core.fault;

/// A core that hands out scripted register states, one per step. Enough of
/// the engine's surface for the seam: a register read, a one-instruction
/// run, and nothing else.
const Fake = struct {
    /// One entry per step, each the value every watched register takes at
    /// that step. A loop is written as a list that returns to its first
    /// entry.
    script: []const u32,
    at: usize = 0,
    /// Stores the fake makes on the way, handed to the seam the way the
    /// write hook would.
    disturbs: []const usize = &.{},
    seam: ?*idle.Seam = null,
    steps: usize = 0,

    pub fn register(self: *Fake, which: anytype) !u32 {
        _ = which;
        return self.script[self.at % self.script.len];
    }

    pub fn runChunk(self: *Fake, start: u32, instructions: usize, watch: ?*fault.Watch) !?fault.Fault {
        _ = start;
        _ = watch;
        self.steps += instructions;
        for (self.disturbs) |when| {
            if (when == self.at) if (self.seam) |s| s.disturb();
        }
        self.at += instructions;
        return null;
    }
};

test "a loop that comes back to its opening state closes" {
    var seam = idle.Seam{};
    var core = Fake{ .script = &.{ 10, 20, 30 }, .seam = &seam };
    const looked = try seam.look(&core, 0, idle.limits.probe);
    try std.testing.expect(looked.closed);
    try std.testing.expectEqual(@as(usize, 3), looked.ran);
    try std.testing.expectEqual(@as(u64, 1), seam.closures);
}

test "a machine that keeps moving does not close" {
    var seam = idle.Seam{};
    var walking = @as([idle.limits.probe + 8]u32, @splat(0));
    for (&walking, 0..) |*slot, index| slot.* = @intCast(index + 1);
    var core = Fake{ .script = &walking, .seam = &seam };
    const looked = try seam.look(&core, 0, idle.limits.probe);
    try std.testing.expect(!looked.closed);
    try std.testing.expectEqual(idle.limits.probe, looked.ran);
    try std.testing.expectEqual(@as(u64, 0), seam.closures);
}

test "a store the model cannot show harmless refuses the closure" {
    var seam = idle.Seam{};
    var core = Fake{ .script = &.{ 10, 20, 30 }, .seam = &seam, .disturbs = &.{1} };
    const looked = try seam.look(&core, 0, idle.limits.probe);
    try std.testing.expect(!looked.closed);
    // Two, not the three it takes to come back round: the probe stops on
    // the disturbing step rather than finishing a loop whose answer is
    // already settled. The steps it did take are still owed to the clocks.
    try std.testing.expectEqual(@as(usize, 2), looked.ran);
    try std.testing.expectEqual(@as(u64, 0), seam.closures);
}

test "a disturbed probe stops stepping instead of running its budget out" {
    var seam = idle.Seam{};
    var walking = @as([idle.limits.probe + 8]u32, @splat(0));
    for (&walking, 0..) |*slot, index| slot.* = @intCast(index + 1);
    var core = Fake{ .script = &walking, .seam = &seam, .disturbs = &.{2} };
    const looked = try seam.look(&core, 0, idle.limits.probe);
    try std.testing.expect(!looked.closed);
    // Without the early exit this walks the whole budget, because the
    // state never returns to its opening and the disturbance is only
    // consulted where a loop closes.
    try std.testing.expectEqual(@as(usize, 3), looked.ran);
    try std.testing.expectEqual(@as(usize, 3), core.steps);
}

test "an undisturbed probe still walks the whole budget" {
    var seam = idle.Seam{};
    var walking = @as([idle.limits.probe + 8]u32, @splat(0));
    for (&walking, 0..) |*slot, index| slot.* = @intCast(index + 1);
    var core = Fake{ .script = &walking, .seam = &seam };
    const looked = try seam.look(&core, 0, idle.limits.probe);
    try std.testing.expectEqual(idle.limits.probe, looked.ran);
}

test "a loop wider than the probe budget is not seen" {
    var seam = idle.Seam{};
    var wide = @as([idle.limits.probe + 4]u32, @splat(0));
    for (&wide, 0..) |*slot, index| slot.* = @intCast(index + 1);
    var core = Fake{ .script = &wide, .seam = &seam };
    const looked = try seam.look(&core, 0, idle.limits.probe);
    try std.testing.expect(!looked.closed);
}

test "a machine proved idle is recognised again without stepping" {
    var seam = idle.Seam{};
    var core = Fake{ .script = &.{ 10, 20, 30 }, .seam = &seam };
    _ = try seam.look(&core, 0, idle.limits.probe);
    const before = core.steps;
    try std.testing.expect(try seam.resting(&core));
    try std.testing.expectEqual(before, core.steps);
}

test "a machine that moved on is no longer resting" {
    var seam = idle.Seam{};
    var core = Fake{ .script = &.{ 10, 20, 30 }, .seam = &seam };
    _ = try seam.look(&core, 0, idle.limits.probe);
    core.at = 1;
    try std.testing.expect(!try seam.resting(&core));
    // And the stale proof is dropped rather than held against a later step.
    try std.testing.expect(seam.known == null);
}

test "nothing is resting before anything has been proved" {
    var seam = idle.Seam{};
    var core = Fake{ .script = &.{42}, .seam = &seam };
    try std.testing.expect(!try seam.resting(&core));
}

test "a skipped stretch is counted, an empty one is not" {
    var seam = idle.Seam{};
    seam.skip(0);
    try std.testing.expectEqual(@as(u64, 0), seam.boundaries);
    seam.skip(50_000);
    seam.skip(50_000);
    try std.testing.expectEqual(@as(u64, 2), seam.boundaries);
    try std.testing.expectEqual(@as(u64, 100_000), seam.skipped);
}

test "ordinary RAM is where a value-for-value store proves nothing changed" {
    try std.testing.expect(idle.plainMemory(0x2200_0000, 4));
    try std.testing.expect(idle.plainMemory(0x2000_0000, 1));
    try std.testing.expect(idle.plainMemory(0x6800_0000, 4));
}

test "the private peripheral bus is not ordinary memory" {
    // Mapped as RAM by the board, but SysTick, the NVIC and the SCB answer
    // on it and act on writes their own read-back does not show.
    try std.testing.expect(!idle.plainMemory(0xE000_E010, 4));
    try std.testing.expect(!idle.plainMemory(0xE000_ED04, 4));
}

test "a peripheral register is not ordinary memory either" {
    try std.testing.expect(!idle.plainMemory(0x4000_0000, 4));
    try std.testing.expect(!idle.plainMemory(0x1_0000_0000, 4));
}

test "a proved seam rests where it stands" {
    var seam = idle.Seam{};
    var core = Fake{ .script = &.{ 10, 20, 30 }, .seam = &seam };
    try std.testing.expect((try seam.look(&core, 0, idle.limits.probe)).closed);
    // Back at the head of the loop, so the cheap path answers without
    // stepping anything.
    try std.testing.expect(try seam.resting(&core));
    try std.testing.expectEqual(@as(usize, 3), core.steps);
}

test "a stirred seam will not rest on a proof an interrupt invalidated" {
    var seam = idle.Seam{};
    var core = Fake{ .script = &.{ 10, 20, 30 }, .seam = &seam };
    try std.testing.expect((try seam.look(&core, 0, idle.limits.probe)).closed);
    try std.testing.expect(try seam.resting(&core));
    // A handler ran. The registers it left behind are identical, which is
    // exactly why the seam cannot be allowed to trust them: the word the
    // loop waits on lives in memory the snapshot never saw.
    seam.stir();
    try std.testing.expect(!(try seam.resting(&core)));
}

test "stirring a seam that proved nothing is harmless" {
    var seam = idle.Seam{};
    var core = Fake{ .script = &.{ 10, 20, 30 }, .seam = &seam };
    seam.stir();
    try std.testing.expect(!(try seam.resting(&core)));
    // And the seam still works afterwards.
    try std.testing.expect((try seam.look(&core, 0, idle.limits.probe)).closed);
}

test "a stir does not discard what the seam has already saved" {
    var seam = idle.Seam{};
    var core = Fake{ .script = &.{ 10, 20, 30 }, .seam = &seam };
    try std.testing.expect((try seam.look(&core, 0, idle.limits.probe)).closed);
    seam.skip(500);
    seam.stir();
    try std.testing.expectEqual(@as(u64, 1), seam.closures);
    try std.testing.expectEqual(@as(u64, 1), seam.boundaries);
    try std.testing.expectEqual(@as(u64, 500), seam.skipped);
}
