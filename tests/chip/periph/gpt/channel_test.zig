//! Covers src/chip/periph/gpt/channel.zig: one channel's counting and the window
//! it answers on.
//!
//! The window is driven through `gpt.Gpt` rather than by calling the
//! channel's own `readByte` and `writeByte`, because the bank is the route
//! every real access takes: it resolves the channel, takes GTWP whole, and
//! breaks the access into the lanes those two see. Reaching past it would
//! test a path no firmware uses. What is being exercised is still the
//! channel, with the bank standing in front of it as the address decoder.
const std = @import("std");
const ra8 = @import("ra8");

const gpt = ra8.chip.periph.gpt;

const ch0 = gpt.win_base;

fn started(unit: *gpt.Gpt, base: u32, period: u32) void {
    unit.write(base + gpt.off.gtpr, 4, period);
    const index = (base - gpt.win_base) / gpt.stride;
    unit.write(base + gpt.off.gtstr, 4, @as(u32, 1) << @intCast(index));
}

test "a stopped channel holds its count" {
    var unit = gpt.Gpt.init();
    unit.write(ch0 + gpt.off.gtpr, 4, 0xFFFF);
    unit.tick();
    try std.testing.expectEqual(@as(u32, 0), unit.read(ch0 + gpt.off.gtcnt, 4));
}

test "a running channel advances by one odd step per boundary" {
    var unit = gpt.Gpt.init();
    started(&unit, ch0, 0xFFFF);
    unit.tick();
    try std.testing.expectEqual(gpt.step_per_tick + 1, unit.read(ch0 + gpt.off.gtcnt, 4));
    unit.tick();
    try std.testing.expectEqual(2 * gpt.step_per_tick + 2, unit.read(ch0 + gpt.off.gtcnt, 4));
}

test "the full 32-bit period still overflows, where dev's sum wrapped first" {
    var unit = gpt.Gpt.init();
    started(&unit, ch0, 0xFFFF_FFFF);
    unit.write(ch0 + gpt.off.gtcnt, 4, 0xFFFF_FFFF - 2);
    unit.tick();
    try std.testing.expectEqual(@as(u32, 1), unit.channels[0].overflows);
    try std.testing.expect(unit.read(ch0 + gpt.off.gtcnt, 4) < gpt.step_per_tick);
}

test "a period shorter than one step keeps the count inside it" {
    var unit = gpt.Gpt.init();
    started(&unit, ch0, 0x0100);
    unit.tick();
    const count = unit.read(ch0 + gpt.off.gtcnt, 4);
    try std.testing.expect(count <= 0x0100);
    try std.testing.expectEqual(
        @as(u32, (gpt.step_per_tick) / 0x0101),
        unit.channels[0].overflows,
    );
}

test "GTPR left at zero counts to the 16-bit wrap" {
    var unit = gpt.Gpt.init();
    unit.write(ch0 + gpt.off.gtstr, 4, 1);
    try std.testing.expectEqual(gpt.default_period, unit.channels[0].periodOrDefault());
    unit.tick();
    try std.testing.expectEqual(gpt.step_per_tick + 1, unit.read(ch0 + gpt.off.gtcnt, 4));
}

test "a status store can only clear a flag, never raise one" {
    var unit = gpt.Gpt.init();
    started(&unit, ch0, 0x8000);
    unit.tick();
    unit.tick();
    unit.write(ch0 + gpt.off.gtst, 4, gpt.status.tcfa);
    try std.testing.expectEqual(@as(u32, 0), unit.read(ch0 + gpt.off.gtst, 4));
    unit.write(ch0 + gpt.off.gtst, 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), unit.read(ch0 + gpt.off.gtst, 4));
}

test "an uninterpreted register keeps what was written" {
    var unit = gpt.Gpt.init();
    unit.write(ch0 + 0x1C, 4, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), unit.read(ch0 + 0x1C, 4));
}

test "a halfword store lands on its own half of the period" {
    var unit = gpt.Gpt.init();
    unit.write(ch0 + gpt.off.gtpr, 4, 0x1234_5678);
    unit.write(ch0 + gpt.off.gtpr + 2, 2, 0xABCD);
    try std.testing.expectEqual(@as(u32, 0xABCD_5678), unit.read(ch0 + gpt.off.gtpr, 4));
}

test "counter reads advance a running channel between boundaries" {
    var unit = gpt.Gpt.init();
    started(&unit, ch0, 0xFFFF);

    try std.testing.expectEqual(@as(u32, 1), unit.read(ch0 + gpt.off.gtcnt, 4));
    try std.testing.expectEqual(@as(u32, 2), unit.read(ch0 + gpt.off.gtcnt, 4));
}

test "counter reads respect the selected prescaler" {
    var unit = gpt.Gpt.init();
    unit.write(ch0 + gpt.off.gtcr, 4, 0x0080_0000 | gpt.control.cst);

    try std.testing.expectEqual(@as(u32, 0), unit.read(ch0 + gpt.off.gtcnt, 4));
    try std.testing.expectEqual(@as(u32, 0), unit.read(ch0 + gpt.off.gtcnt, 4));
    try std.testing.expectEqual(@as(u32, 0), unit.read(ch0 + gpt.off.gtcnt, 4));
    try std.testing.expectEqual(@as(u32, 1), unit.read(ch0 + gpt.off.gtcnt, 4));
}
