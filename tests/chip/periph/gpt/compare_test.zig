//! GTCCRA and GTCCRB: the crossing rule, the pair's bookkeeping, and what a
//! channel does with a compare value once the count walks past it.
const std = @import("std");

const ra8 = @import("ra8");
const compare = ra8.chip.periph.gpt_compare;
const gpt = ra8.chip.periph.gpt;

/// A channel started with a period, so a test only has to say what to compare.
fn running(period: u32) gpt.Channel {
    var channel = gpt.Channel{};
    channel.period.set(.live, period);
    channel.cr = gpt.control.cst;
    return channel;
}

test "crossed: an in-range chunk covers the values above where it started" {
    try std.testing.expect(compare.crossed(0x100, 0x200, 0, 0x180));
    try std.testing.expect(compare.crossed(0x100, 0x200, 0, 0x200));
    try std.testing.expect(!compare.crossed(0x100, 0x200, 0, 0x100));
    try std.testing.expect(!compare.crossed(0x100, 0x200, 0, 0x0FF));
    try std.testing.expect(!compare.crossed(0x100, 0x200, 0, 0x201));
}

test "crossed: one wrap covers both halves of the span" {
    try std.testing.expect(compare.crossed(0xF000, 0x0100, 1, 0xF800));
    try std.testing.expect(compare.crossed(0xF000, 0x0100, 1, 0x0100));
    try std.testing.expect(!compare.crossed(0xF000, 0x0100, 1, 0x0101));
    try std.testing.expect(!compare.crossed(0xF000, 0x0100, 1, 0xF000));
}

test "crossed: two wraps visit everything" {
    try std.testing.expect(compare.crossed(0x10, 0x20, 2, 0x00));
    try std.testing.expect(compare.crossed(0x10, 0x20, 7, 0xFFFF_FFFF));
}

test "a fresh pair is quiet and unarmed" {
    const pair = compare.Pair{};
    try std.testing.expect(pair.quiet());
    try std.testing.expect(!pair.armed(.a));
    try std.testing.expect(!pair.armed(.b));
}

test "setting a compare arms it, counts the write and leaves it quiet no longer" {
    var pair = compare.Pair{};
    pair.set(.a, 0x40);
    try std.testing.expect(pair.armed(.a));
    try std.testing.expectEqual(@as(u32, 0x40), pair.value(.a));
    try std.testing.expectEqual(@as(u32, 1), pair.writes);
    try std.testing.expect(!pair.quiet());
}

test "a compare written back to zero is unarmed again" {
    var pair = compare.Pair{};
    pair.set(.b, 0x40);
    pair.set(.b, 0);
    try std.testing.expect(!pair.armed(.b));
    try std.testing.expectEqual(@as(u32, 0), pair.step(0, 0x100, 0, 0xFFFF));
}

test "a step past an armed compare raises its flag and counts the match" {
    var pair = compare.Pair{};
    pair.set(.a, 0x80);
    try std.testing.expectEqual(compare.flag.tcfa, pair.step(0, 0x100, 0, 0xFFFF));
    try std.testing.expectEqual(@as(u32, 1), pair.matches(.a));
    try std.testing.expectEqual(@as(u32, 0), pair.matches(.b));
}

test "both compares inside one chunk raise both flags" {
    var pair = compare.Pair{};
    pair.set(.a, 0x20);
    pair.set(.b, 0x60);
    try std.testing.expectEqual(compare.flag.both, pair.step(0, 0x100, 0, 0xFFFF));
}

test "a step that stops short of the compare raises nothing" {
    var pair = compare.Pair{};
    pair.set(.a, 0x400);
    try std.testing.expectEqual(@as(u32, 0), pair.step(0, 0x100, 0, 0xFFFF));
    try std.testing.expectEqual(@as(u32, 0), pair.matches(.a));
}

test "which(): only the two compared registers claim an offset" {
    try std.testing.expectEqual(compare.Which.a, compare.which(compare.off.gtccra).?);
    try std.testing.expectEqual(compare.Which.a, compare.which(compare.off.gtccra + 3).?);
    try std.testing.expectEqual(compare.Which.b, compare.which(compare.off.gtccrb).?);
    try std.testing.expect(compare.which(gpt.off.gtcnt) == null);
    try std.testing.expect(compare.which(gpt.off.gtpr) == null);
    try std.testing.expect(compare.which(compare.off.gtccrb + 4) == null);
}

test "a channel reads back what was written to GTCCRA, byte lane by byte lane" {
    var unit = gpt.Gpt.init();
    unit.write(gpt.win_base + compare.off.gtccra, 4, 0x1234_5678);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), unit.read(gpt.win_base + compare.off.gtccra, 4));
    unit.write(gpt.win_base + compare.off.gtccra + 2, 2, 0xABCD);
    try std.testing.expectEqual(@as(u32, 0xABCD_5678), unit.read(gpt.win_base + compare.off.gtccra, 4));
}

test "a channel counting past GTCCRA raises GTST.TCFA" {
    var channel = running(0xFFFF);
    channel.compares.set(.a, gpt.step_per_tick - 1);
    _ = channel.tick();
    try std.testing.expect(channel.st & gpt.status.tcfa != 0);
    try std.testing.expect(channel.st & gpt.status.tcfb == 0);
    try std.testing.expectEqual(@as(u32, 1), channel.compares.matches(.a));
}

test "a compare above the count waits for the chunk that reaches it" {
    var channel = running(0xFFFF);
    // Three steps of 0x4001 land on 0xC003, so 0xC000 falls in the third.
    channel.compares.set(.b, 0xC000);
    _ = channel.tick();
    try std.testing.expect(channel.st & gpt.status.tcfb == 0);
    _ = channel.tick();
    try std.testing.expect(channel.st & gpt.status.tcfb == 0);
    _ = channel.tick();
    try std.testing.expect(channel.st & gpt.status.tcfb != 0);
    try std.testing.expectEqual(@as(u32, 1), channel.compares.matches(.b));
}

test "a compare is still reached on the chunk the counter wraps in" {
    var channel = running(0x100);
    channel.cnt = 0x80;
    channel.compares.set(.a, 0x40);
    const wraps = channel.tick();
    try std.testing.expect(wraps > 0);
    try std.testing.expect(channel.st & gpt.status.tcfpo != 0);
    try std.testing.expect(channel.st & gpt.status.tcfa != 0);
}

test "a stopped channel compares nothing" {
    var channel = gpt.Channel{};
    channel.period.set(.live, 0xFFFF);
    channel.compares.set(.a, 0x10);
    try std.testing.expectEqual(@as(u32, 0), channel.tick());
    try std.testing.expect(channel.st & gpt.status.tcfa == 0);
}

test "GTST clears a compare flag by writing the word back with the bit zero" {
    var unit = gpt.Gpt.init();
    unit.channels[0].period.set(.live, 0xFFFF);
    unit.channels[0].cr = gpt.control.cst;
    unit.channels[0].compares.set(.a, 0x10);
    unit.tick();
    try std.testing.expect(unit.read(gpt.win_base + gpt.off.gtst, 4) & gpt.status.tcfa != 0);
    unit.write(gpt.win_base + gpt.off.gtst, 4, 0);
    try std.testing.expect(unit.read(gpt.win_base + gpt.off.gtst, 4) & gpt.status.tcfa == 0);
}

test "a store to GTST cannot raise a compare flag the channel never earned" {
    var unit = gpt.Gpt.init();
    unit.write(gpt.win_base + gpt.off.gtst, 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), unit.read(gpt.win_base + gpt.off.gtst, 4));
}

test "a channel with a compare programmed is no longer quiet" {
    var channel = gpt.Channel{};
    try std.testing.expect(channel.quiet());
    channel.compares.set(.a, 0x10);
    try std.testing.expect(!channel.quiet());
}

test "a compare above the period never matches, however often a saw wraps" {
    var channel = running(0x100);
    channel.compares.set(.a, 0x180);
    channel.compares.set(.b, 0x80);
    // One tick steps far past a 0x100 period, so each one wraps.
    var ticks: u32 = 0;
    while (ticks < 4) : (ticks += 1) try std.testing.expect(channel.tick() > 0);
    try std.testing.expect(channel.st & gpt.status.tcfa == 0);
    try std.testing.expectEqual(@as(u32, 0), channel.compares.matches(.a));
    // The in-range compare on the same channel still matches on every tick.
    try std.testing.expect(channel.st & gpt.status.tcfb != 0);
    try std.testing.expectEqual(@as(u32, 4), channel.compares.matches(.b));
}

test "a pair step skips a compare above the period it is given" {
    var pair = compare.Pair{};
    pair.set(.a, 0x180);
    try std.testing.expectEqual(@as(u32, 0), pair.step(0xF0, 0x10, 1, 0x100));
    try std.testing.expectEqual(compare.flag.tcfa, pair.step(0xF0, 0x10, 1, 0x200));
}
