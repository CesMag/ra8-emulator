//! GTCR.TPCS: the clock a GPT channel counts on.
const std = @import("std");
const testing = std.testing;

const ra8 = @import("ra8");
const clk = ra8.chip.periph.gpt.clock;
const gpt = ra8.chip.periph.gpt;

/// A GTCR word carrying a prescaler encoding and the start bit.
fn control(encoding: u32) u32 {
    return clk.field.cst | (encoding << 23);
}

test "an empty GTCR selects the undivided clock" {
    try testing.expectEqual(clk.Source.pclkd, clk.sourceOf(0));
    try testing.expectEqual(@as(u32, 1), clk.Source.pclkd.divider());
}

test "each named encoding selects its own divider" {
    const named = [_]struct { encoding: u32, source: clk.Source, divider: u32 }{
        .{ .encoding = 0, .source = .pclkd, .divider = 1 },
        .{ .encoding = 1, .source = .pclkd_div4, .divider = 4 },
        .{ .encoding = 2, .source = .pclkd_div16, .divider = 16 },
        .{ .encoding = 3, .source = .pclkd_div64, .divider = 64 },
        .{ .encoding = 4, .source = .pclkd_div256, .divider = 256 },
        .{ .encoding = 5, .source = .pclkd_div1024, .divider = 1024 },
    };
    for (named) |case| {
        const source = clk.sourceOf(control(case.encoding));
        try testing.expectEqual(case.source, source);
        try testing.expectEqual(case.divider, source.divider());
    }
}

test "the start bit and the mode field do not disturb the prescaler" {
    const cr = control(5) | clk.field.md;
    try testing.expectEqual(clk.Source.pclkd_div1024, clk.sourceOf(cr));
}

test "an encoding nobody names counts undivided and says so" {
    const source = clk.sourceOf(control(9));
    try testing.expectEqual(@as(u32, 1), source.divider());
    try testing.expectEqualStrings("unknown count source", source.name());
}

test "every named encoding has a name that is not the unknown one" {
    const named = [_]clk.Source{
        .pclkd,       .pclkd_div4,   .pclkd_div16,
        .pclkd_div64, .pclkd_div256, .pclkd_div1024,
    };
    for (named) |source| {
        try testing.expect(!std.mem.eql(u8, "unknown count source", source.name()));
    }
}

test "a divided step is smaller, and strictly ordered by divider" {
    const per = gpt.step_per_tick;
    var previous = clk.step(per, .pclkd) + 1;
    const ordered = [_]clk.Source{
        .pclkd,       .pclkd_div4,   .pclkd_div16,
        .pclkd_div64, .pclkd_div256, .pclkd_div1024,
    };
    for (ordered) |source| {
        const step = clk.step(per, source);
        try testing.expect(step < previous);
        previous = step;
    }
}

test "a divided step stays odd, so it stays coprime to a saw period" {
    const per = gpt.step_per_tick;
    const ordered = [_]clk.Source{
        .pclkd,       .pclkd_div4,   .pclkd_div16,
        .pclkd_div64, .pclkd_div256, .pclkd_div1024,
    };
    for (ordered) |source| {
        try testing.expectEqual(@as(u32, 1), clk.step(per, source) & 1);
    }
}

test "the slowest divider still moves the counter" {
    try testing.expect(clk.step(4, .pclkd_div1024) >= 1);
    try testing.expect(clk.step(1, .pclkd_div1024) >= 1);
}

test "a channel reports the source its GTCR selects" {
    var channel = gpt.Channel{};
    channel.cr = control(2);
    try testing.expectEqual(clk.Source.pclkd_div16, channel.source());
    try testing.expect(channel.running());
}

test "a slowed channel counts behind an undivided one" {
    var fast = gpt.Channel{};
    var slow = gpt.Channel{};
    fast.cr = control(0);
    slow.cr = control(4);
    fast.period.set(.live, 0xFFFF_FFFF);
    slow.period.set(.live, 0xFFFF_FFFF);
    _ = fast.tick();
    _ = slow.tick();
    try testing.expect(slow.cnt < fast.cnt);
    try testing.expect(slow.cnt > 0);
}

test "a slowed channel overflows later than an undivided one" {
    var fast = gpt.Channel{};
    var slow = gpt.Channel{};
    fast.cr = control(0);
    slow.cr = control(3);
    fast.period.set(.live, 0x0001_0000);
    slow.period.set(.live, 0x0001_0000);
    var index: usize = 0;
    while (index < 8) : (index += 1) {
        _ = fast.tick();
        _ = slow.tick();
    }
    try testing.expect(fast.overflows > slow.overflows);
}

test "a stopped channel counts at no source at all" {
    var channel = gpt.Channel{};
    channel.cr = 0;
    channel.period.set(.live, 0xFFFF);
    try testing.expectEqual(@as(u32, 0), channel.tick());
    try testing.expectEqual(@as(u32, 0), channel.cnt);
}

test "an unnamed encoding counts at the undivided rate" {
    var named = gpt.Channel{};
    var unnamed = gpt.Channel{};
    named.cr = control(0);
    unnamed.cr = control(12);
    named.period.set(.live, 0xFFFF_FFFF);
    unnamed.period.set(.live, 0xFFFF_FFFF);
    _ = named.tick();
    _ = unnamed.tick();
    try testing.expectEqual(named.cnt, unnamed.cnt);
}

test "the prescaler survives a readback through the window" {
    var unit = gpt.Gpt.init();
    const address = gpt.win_base + gpt.off.gtcr;
    unit.write(address, 4, control(5));
    try testing.expectEqual(control(5), unit.read(address, 4));
    try testing.expectEqual(clk.Source.pclkd_div1024, unit.channels[0].source());
}

test "a byte store to GTCR's top lane changes the prescaler alone" {
    var unit = gpt.Gpt.init();
    const address = gpt.win_base + gpt.off.gtcr;
    unit.write(address, 4, clk.field.cst);
    // TPCS starts at bit 23, so the top byte lane carries its upper three
    // bits: 0x01 there is encoding 2, PCLKD/16.
    unit.write(address + 3, 1, 0x01);
    try testing.expectEqual(clk.Source.pclkd_div16, unit.channels[0].source());
    try testing.expect(unit.channels[0].running());
}

test "two channels of one unit can count at different rates" {
    var unit = gpt.Gpt.init();
    unit.write(gpt.win_base + gpt.off.gtcr, 4, control(0));
    unit.write(gpt.win_base + gpt.stride + gpt.off.gtcr, 4, control(5));
    unit.write(gpt.win_base + gpt.off.gtpr, 4, 0xFFFF_FFFF);
    unit.write(gpt.win_base + gpt.stride + gpt.off.gtpr, 4, 0xFFFF_FFFF);
    unit.tick();
    try testing.expect(unit.channels[1].cnt < unit.channels[0].cnt);
}

test "an overflow is due one count past the period, rounded up" {
    // 0xFFFF - 0xFFF0 + 1 = 16 counts at 1 GHz is 16 ns.
    try testing.expectEqual(@as(?u64, 16), clk.overflowInNs(0xFFF0, 0xFFFF, .pclkd, 1_000_000_000));
    // The divider multiplies the edges: one count at PCLKD/1024 is 1024.
    try testing.expectEqual(@as(?u64, 1024), clk.overflowInNs(0, 0, .pclkd_div1024, 1_000_000_000));
    // 3 counts at 2 Hz is 1.5 s; one edge at 3 Hz rounds up, never early.
    try testing.expectEqual(@as(?u64, 1_500_000_000), clk.overflowInNs(5, 7, .pclkd, 2));
    try testing.expectEqual(@as(?u64, 333_333_334), clk.overflowInNs(9, 9, .pclkd, 3));
    // Past the period, it wraps on the next edge. No clock, nothing due.
    try testing.expectEqual(@as(?u64, 1), clk.overflowInNs(20, 9, .pclkd, 1_000_000_000));
    try testing.expectEqual(@as(?u64, null), clk.overflowInNs(0, 7, .pclkd, 0));
}

test "a running saw channel is due at its wrap on the derived PCLKD" {
    const sched = clk.sched;
    try testing.expectEqual(@as(u64, 327_700_000), sched.pclkd_hz);
    var channel = ra8.chip.periph.gpt.channel.Channel{};
    try testing.expectEqual(@as(?u64, null), sched.dueAt(channel, 0));
    channel.cr = control(0);
    // GTPR = 0 counts to 0xFFFF: 65536 counts, rounded up to 199988 ns.
    try testing.expectEqual(@as(?u64, 1_000 + 199_988), sched.dueAt(channel, 1_000));
    // At PCLKD/4 the same wrap takes four times the edges.
    channel.cr = control(1);
    try testing.expectEqual(@as(?u64, 799_952), sched.dueAt(channel, 0));
}

test "one boundary of steps lands on the derived due time" {
    // 0x4001 counts at the undivided clock take exactly one 50000 ns
    // boundary, which is what keeps the later queue switch corpus-identical.
    const sched = clk.sched;
    try testing.expectEqual(@as(?u64, 50_000), clk.overflowInNs(0, gpt.step_per_tick - 1, .pclkd, sched.pclkd_hz));
}

test "a GPT boundary counts the counts its virtual time passes" {
    const sched = clk.sched;
    // A full 50000 ns boundary at PCLKD is exactly the old step.
    try testing.expectEqual(@as(u32, gpt.step_per_tick), sched.countsBetween(0, 50_000, 1));
    // At /4 the true quotient is kept: four boundaries sum to the full step.
    var total: u32 = 0;
    var at: u64 = 0;
    while (at < 200_000) : (at += 50_000) total += sched.countsBetween(at, at + 50_000, 4);
    try testing.expectEqual(@as(u32, gpt.step_per_tick), total);
    // A narrowed 2000 ns boundary counts a narrow stretch, not a whole step.
    try testing.expectEqual(@as(u32, 655), sched.countsBetween(0, 2_000, 1));
}

test "a GPT overflow is raised on the boundary its due time falls in" {
    var timer = gpt.Gpt.init();
    timer.channels[0].cr = control(0);
    const due = clk.sched.dueAt(timer.channels[0], 0).?;
    var at: u64 = 0;
    while (at + 1_000 < due) : (at += 1_000) {
        clk.sched.tickFor(&timer, at, at + 1_000);
        try testing.expect(!timer.pending);
    }
    clk.sched.tickFor(&timer, at, due);
    try testing.expect(timer.pending);
    try testing.expectEqual(@as(u32, 1), timer.channels[0].overflows);
}

test "a compare match is due where GTCNT reaches GTCCRA, this cycle or after the wrap" {
    const sched = clk.sched;
    var channel = ra8.chip.periph.gpt.channel.Channel{};
    channel.cr = control(0);
    try testing.expectEqual(@as(?u64, null), sched.compareDueAt(channel, .a, 0));
    // 0x4001 counts ahead is exactly one 50000 ns boundary.
    channel.compares.a = gpt.step_per_tick;
    try testing.expectEqual(@as(?u64, 50_000), sched.compareDueAt(channel, .a, 0));
    // Behind the count, a saw matches after the wrap: 0x10000 - 0x5000 + 0x4001.
    channel.cnt = 0x5000;
    const wrapped = sched.compareDueAt(channel, .a, 0).?;
    try testing.expectEqual(sched.countsBetween(0, wrapped, 1), 0x10000 - 0x5000 + 0x4001);
    try testing.expect(sched.countsBetween(0, wrapped - 1, 1) < 0x10000 - 0x5000 + 0x4001);
    // A one-shot never comes back round, and above GTPR is never reached.
    channel.cr = control(0) | 0x0001_0000;
    try testing.expectEqual(@as(?u64, null), sched.compareDueAt(channel, .a, 0));
    channel.cr = control(0);
    channel.period.live = 0x3000;
    try testing.expectEqual(@as(?u64, null), sched.compareDueAt(channel, .a, 0));
}

test "a compare-A match is flagged on the boundary that reaches its due time" {
    var timer = gpt.Gpt.init();
    const channel = &timer.channels[0];
    channel.cr = control(1);
    channel.cnt = 0x9000;
    channel.compares.a = 0x2345;
    const start: u64 = 7_777;
    const due = clk.sched.compareDueAt(channel.*, .a, start).?;
    var at = start;
    while (at + 3_001 < due) : (at += 3_001) {
        clk.sched.tickFor(&timer, at, at + 3_001);
        try testing.expect(channel.st & ra8.chip.periph.gpt.channel.status.tcfa == 0);
    }
    clk.sched.tickFor(&timer, at, due - 1);
    try testing.expect(channel.st & ra8.chip.periph.gpt.channel.status.tcfa == 0);
    clk.sched.tickFor(&timer, due - 1, due);
    try testing.expect(channel.st & ra8.chip.periph.gpt.channel.status.tcfa != 0);
}

fn triangle(encoding: u32) u32 {
    return control(encoding) | 0x0004_0000;
}

test "a triangle's peak and trough are due where the folded phase reaches them" {
    const sched = clk.sched;
    var channel = ra8.chip.periph.gpt.channel.Channel{};
    channel.cr = triangle(0);
    channel.period.live = 100_000;
    channel.cnt = 30_000;
    // Rising from 30000: the peak is 70000 counts on, the trough 170000.
    const peak = sched.turnDueAt(channel, .peak, 0).?;
    try testing.expectEqual(@as(?u64, peak), sched.dueAt(channel, 0));
    try testing.expectEqual(@as(u32, 70_000), sched.countsBetween(0, peak, 1));
    try testing.expect(sched.countsBetween(0, peak - 1, 1) < 70_000);
    const trough = sched.turnDueAt(channel, .trough, 0).?;
    try testing.expectEqual(@as(u32, 170_000), sched.countsBetween(0, trough, 1));
    // Falling through 30000, the trough comes first and the peak a cycle on.
    channel.rising = false;
    try testing.expectEqual(@as(u32, 30_000), sched.countsBetween(0, sched.turnDueAt(channel, .trough, 0).?, 1));
    try testing.expectEqual(@as(u32, 130_000), sched.countsBetween(0, sched.turnDueAt(channel, .peak, 0).?, 1));
    // A saw has no turns, and a stopped triangle nothing due.
    channel.cr = control(0);
    try testing.expectEqual(@as(?u64, null), sched.turnDueAt(channel, .peak, 0));
    channel.cr = 0x0004_0000;
    try testing.expectEqual(@as(?u64, null), sched.dueAt(channel, 0));
}

test "a triangle peak is flagged on the boundary that reaches its due time" {
    var timer = gpt.Gpt.init();
    const channel = &timer.channels[0];
    channel.cr = triangle(2);
    channel.period.live = 0x8000;
    channel.cnt = 0x1234;
    const start: u64 = 4_321;
    const due = clk.sched.dueAt(channel.*, start).?;
    var at = start;
    while (at + 2_999 < due) : (at += 2_999) {
        clk.sched.tickFor(&timer, at, at + 2_999);
        try testing.expect(!timer.pending);
        try testing.expect(channel.st & ra8.chip.periph.gpt.channel.status.tcfpo == 0);
    }
    clk.sched.tickFor(&timer, at, due - 1);
    try testing.expect(channel.st & ra8.chip.periph.gpt.channel.status.tcfpo == 0);
    clk.sched.tickFor(&timer, due - 1, due);
    try testing.expect(channel.st & ra8.chip.periph.gpt.channel.status.tcfpo != 0);
    try testing.expect(timer.pending);
    try testing.expect(!channel.rising);
}
