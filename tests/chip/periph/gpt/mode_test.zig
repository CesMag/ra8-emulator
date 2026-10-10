//! GTCR.MD: the shape a GPT channel counts in.
const std = @import("std");
const testing = std.testing;

const ra8 = @import("ra8");
const md = ra8.chip.periph.gpt_mode;
const gpt = ra8.chip.periph.gpt;

/// A GTCR word carrying a mode encoding and the start bit.
fn control(encoding: u32) u32 {
    return gpt.control.cst | (encoding << md.field.shift);
}

test "an empty GTCR selects saw PWM" {
    try testing.expectEqual(md.Mode.saw_pwm, md.modeOf(0));
    try testing.expect(!md.Mode.saw_pwm.symmetric());
    try testing.expect(!md.Mode.saw_pwm.once());
}

test "each named encoding selects its own mode" {
    const named = [_]struct { encoding: u32, mode: md.Mode }{
        .{ .encoding = 0, .mode = .saw_pwm },
        .{ .encoding = 1, .mode = .saw_one_shot },
        .{ .encoding = 4, .mode = .triangle_pwm },
        .{ .encoding = 5, .mode = .triangle_pwm2 },
        .{ .encoding = 6, .mode = .triangle_pwm3 },
    };
    for (named) |case| {
        try testing.expectEqual(case.mode, md.modeOf(control(case.encoding)));
    }
}

test "the start bit and the prescaler do not disturb the mode" {
    const cr = control(4) | ra8.chip.periph.gpt_clock.field.tpcs;
    try testing.expectEqual(md.Mode.triangle_pwm, md.modeOf(cr));
}

test "an encoding nobody names counts as a saw and says so" {
    const unnamed = md.modeOf(control(7));
    try testing.expect(!unnamed.symmetric());
    try testing.expect(!unnamed.once());
    try testing.expectEqualStrings("unknown counter mode", unnamed.name());
}

test "a saw in range just advances" {
    const step = md.advance(.saw_pwm, 10, true, 1000, 15);
    try testing.expectEqual(@as(u32, 25), step.cnt);
    try testing.expectEqual(@as(u32, 0), step.peaks);
    try testing.expect(!step.halted);
}

test "a saw past the period wraps and counts every wrap" {
    const step = md.advance(.saw_pwm, 0, true, 99, 250);
    try testing.expectEqual(@as(u32, 50), step.cnt);
    try testing.expectEqual(@as(u32, 2), step.peaks);
    try testing.expectEqual(@as(u32, 0), step.troughs);
}

test "a one-shot stops at the period and halts the channel" {
    const step = md.advance(.saw_one_shot, 90, true, 99, 250);
    try testing.expectEqual(@as(u32, 99), step.cnt);
    try testing.expectEqual(@as(u32, 1), step.peaks);
    try testing.expect(step.halted);
}

test "a one-shot still inside its period keeps running" {
    const step = md.advance(.saw_one_shot, 10, true, 99, 20);
    try testing.expectEqual(@as(u32, 30), step.cnt);
    try testing.expect(!step.halted);
}

test "a triangle turns at the period and comes back down" {
    const step = md.advance(.triangle_pwm, 90, true, 100, 15);
    try testing.expectEqual(@as(u32, 95), step.cnt);
    try testing.expect(!step.rising);
    try testing.expectEqual(@as(u32, 1), step.peaks);
    try testing.expectEqual(@as(u32, 0), step.troughs);
}

test "a falling triangle keeps falling" {
    const step = md.advance(.triangle_pwm, 95, false, 100, 15);
    try testing.expectEqual(@as(u32, 80), step.cnt);
    try testing.expect(!step.rising);
    try testing.expectEqual(@as(u32, 0), step.peaks);
}

test "a triangle reaching zero turns again and counts the trough" {
    const step = md.advance(.triangle_pwm, 10, false, 100, 30);
    try testing.expectEqual(@as(u32, 20), step.cnt);
    try testing.expect(step.rising);
    try testing.expectEqual(@as(u32, 1), step.troughs);
    try testing.expectEqual(@as(u32, 0), step.peaks);
}

test "a chunk wider than the cycle counts every peak and trough" {
    const step = md.advance(.triangle_pwm, 0, true, 100, 400);
    try testing.expectEqual(@as(u32, 0), step.cnt);
    try testing.expectEqual(@as(u32, 2), step.peaks);
    try testing.expectEqual(@as(u32, 2), step.troughs);
}

test "the three triangle encodings count the same shape" {
    const shapes = [_]md.Mode{ .triangle_pwm, .triangle_pwm2, .triangle_pwm3 };
    for (shapes) |shape| {
        const step = md.advance(shape, 90, true, 100, 15);
        try testing.expectEqual(@as(u32, 95), step.cnt);
        try testing.expect(!step.rising);
    }
}

test "a visited span widens to the end a turn reached" {
    const turned = md.advance(.triangle_pwm, 90, true, 100, 15);
    const span = md.visited(90, turned, 100);
    try testing.expectEqual(@as(u32, 90), span.lo);
    try testing.expectEqual(@as(u32, 100), span.hi);

    const straight = md.advance(.triangle_pwm, 10, true, 100, 20);
    const flat = md.visited(10, straight, 100);
    try testing.expectEqual(@as(u32, 10), flat.lo);
    try testing.expectEqual(@as(u32, 30), flat.hi);
}

test "a channel in triangle mode falls back to zero and raises the underflow" {
    var channel = gpt.Channel{};
    channel.period.set(.live, gpt.step_per_tick);
    channel.cr = control(4);
    channel.rising = true;

    _ = channel.tick();
    try testing.expectEqual(@as(u32, gpt.step_per_tick), channel.cnt);
    try testing.expect(!channel.rising);
    try testing.expect(channel.st & gpt.status.tcfpo != 0);

    _ = channel.tick();
    try testing.expectEqual(@as(u32, 0), channel.cnt);
    try testing.expect(channel.st & gpt.status.tcfpu != 0);
    try testing.expectEqual(@as(u32, 1), channel.underflows);
}

test "a channel in one-shot mode stops itself at the period" {
    var channel = gpt.Channel{};
    channel.period.set(.live, 16);
    channel.cr = control(1);

    _ = channel.tick();
    try testing.expectEqual(@as(u32, 16), channel.cnt);
    try testing.expect(!channel.running());
    try testing.expectEqual(@as(u32, 1), channel.overflows);

    _ = channel.tick();
    try testing.expectEqual(@as(u32, 16), channel.cnt);
}

test "a saw channel is unchanged by the mode field being read" {
    var channel = gpt.Channel{};
    channel.period.set(.live, 0x0000_2000);
    channel.cr = gpt.control.cst;

    const wraps = channel.tick();
    try testing.expectEqual(@as(u32, 1), wraps);
    try testing.expectEqual(@as(u32, 0x0000_2000), channel.cnt);
    try testing.expect(channel.rising);
    try testing.expectEqual(@as(u32, 0), channel.underflows);
}

test "a triangle passing a compare on the way down still matches" {
    var channel = gpt.Channel{};
    channel.period.set(.live, gpt.step_per_tick);
    channel.cr = control(4);
    channel.compares.set(.a, gpt.step_per_tick / 2);

    _ = channel.tick();
    const rising_matches = channel.compares.matches(.a);
    try testing.expectEqual(@as(u32, 1), rising_matches);

    _ = channel.tick();
    try testing.expectEqual(@as(u32, 2), channel.compares.matches(.a));
    try testing.expect(channel.st & gpt.status.tcfa != 0);
}

test "a channel whose MD never moved has nothing to log" {
    var log = md.Log{};
    // Byte stores that leave MD where it was: CST going up and down.
    _ = log.note(control(0), control(0));
    _ = log.note(control(0), 0);
    try testing.expect(log.quiet());
    try testing.expectEqual(@as(u32, 0), log.changes);
    try testing.expect(!log.overwritten(.saw_pwm));
}

test "the first shape MD moves to is the one the channel asked for" {
    var log = md.Log{};
    _ = log.note(control(0), control(1));
    try testing.expect(!log.quiet());
    try testing.expectEqual(md.Mode.saw_one_shot, log.first.?);
    try testing.expectEqual(@as(u32, 1), log.changes);
    try testing.expect(!log.overwritten(.saw_one_shot));
}

test "a later store moving MD back is an overwrite, and the first shape stands" {
    var log = md.Log{};
    // ra8_gpt_init selects the one-shot, ra8_gpt_start_free_run writes
    // GTCR = 0x00000001, which is CST with MD zero.
    _ = log.note(control(0), control(1));
    _ = log.note(control(1), control(0));
    try testing.expectEqual(md.Mode.saw_one_shot, log.first.?);
    try testing.expectEqual(@as(u32, 2), log.changes);
    try testing.expect(log.overwritten(.saw_pwm));
}

test "a store that does not move MD is not a change" {
    var log = md.Log{};
    _ = log.note(control(0), control(4));
    const before = log.changes;
    // Three of the four byte stores of a word write leave MD alone.
    _ = log.note(control(4), control(4));
    _ = log.note(control(4), md.field.md & control(4));
    try testing.expectEqual(before, log.changes);
    try testing.expectEqual(md.Mode.triangle_pwm, log.first.?);
}

test "note hands the caller back the word it was given" {
    var log = md.Log{};
    try testing.expectEqual(control(1), log.note(control(0), control(1)));
    try testing.expectEqual(@as(u32, 0), log.note(control(1), 0));
}

test "a channel left in the shape it first asked for is not overwritten" {
    var log = md.Log{};
    _ = log.note(control(0), control(6));
    _ = log.note(control(6), control(6) & ~gpt.control.cst);
    try testing.expectEqual(@as(u32, 1), log.changes);
    try testing.expect(!log.overwritten(.triangle_pwm3));
}
