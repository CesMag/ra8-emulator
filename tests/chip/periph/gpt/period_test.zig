const std = @import("std");
const testing = std.testing;

const gpt = @import("ra8").chip.periph.gpt;
const period = @import("ra8").chip.periph.gpt.period;

const base = gpt.win_base;

fn started(unit: *gpt.Gpt) void {
    unit.write(base + gpt.protection.off.gtwp, 4, 0xA500);
    unit.write(base + gpt.periods.off.gtpr, 4, 0x1000);
    unit.write(base + gpt.off.gtstr, 4, 1);
}

test "an unwritten buffer is never handed over" {
    var unit = gpt.Gpt.init();
    started(&unit);
    var spins: u32 = 0;
    while (spins < 4) : (spins += 1) unit.tick();
    try testing.expectEqual(@as(u32, 0x1000), unit.read(base + gpt.periods.off.gtpr, 4));
    try testing.expectEqual(@as(u32, 0), unit.channels[0].period.loads);
}

test "a period parked in GTPBR becomes live at the end of a cycle" {
    var unit = gpt.Gpt.init();
    started(&unit);
    unit.write(base + gpt.periods.off.gtpbr, 4, 0x2000);
    try testing.expectEqual(@as(u32, 0x2000), unit.read(base + gpt.periods.off.gtpbr, 4));
    // Not yet: the parked period waits for a cycle to finish.
    try testing.expectEqual(@as(u32, 0x1000), unit.read(base + gpt.periods.off.gtpr, 4));
    var spins: u32 = 0;
    while (spins < 2) : (spins += 1) unit.tick();
    try testing.expectEqual(@as(u32, 0x2000), unit.read(base + gpt.periods.off.gtpr, 4));
    try testing.expect(unit.channels[0].period.changes >= 1);
}

test "the count stays inside the period it was given" {
    var unit = gpt.Gpt.init();
    started(&unit);
    unit.write(base + gpt.periods.off.gtpbr, 4, 0x2000);
    var spins: u32 = 0;
    while (spins < 8) : (spins += 1) {
        unit.tick();
        try testing.expect(unit.read(base + gpt.off.gtcnt, 4) <= 0x2000);
    }
}

test "a stopped channel keeps the parked period until it runs" {
    var unit = gpt.Gpt.init();
    unit.write(base + gpt.protection.off.gtwp, 4, 0xA500);
    unit.write(base + gpt.periods.off.gtpr, 4, 0x1000);
    unit.write(base + gpt.periods.off.gtpbr, 4, 0x2000);
    var spins: u32 = 0;
    while (spins < 4) : (spins += 1) unit.tick();
    try testing.expectEqual(@as(u32, 0x1000), unit.read(base + gpt.periods.off.gtpr, 4));
    try testing.expectEqual(@as(u32, 0), unit.channels[0].period.loads);
    try testing.expect(unit.channels[0].period.parked);
}

test "GTPBR takes a narrow store on its own lane" {
    var unit = gpt.Gpt.init();
    unit.write(base + gpt.protection.off.gtwp, 4, 0xA500);
    unit.write(base + gpt.periods.off.gtpbr, 4, 0x1122_3344);
    unit.write(base + gpt.periods.off.gtpbr + 2, 2, 0xBEEF);
    try testing.expectEqual(@as(u32, 0xBEEF_3344), unit.read(base + gpt.periods.off.gtpbr, 4));
}

test "GTPBR is behind the write protection the HAL brackets it with" {
    var unit = gpt.Gpt.init();
    unit.write(base + gpt.protection.off.gtwp, 4, 0xA501);
    unit.write(base + gpt.periods.off.gtpbr, 4, 0x2000);
    try testing.expectEqual(@as(u32, 0), unit.read(base + gpt.periods.off.gtpbr, 4));
    try testing.expect(!unit.channels[0].period.parked);
}

test "parking the period the channel already has is a load but not a change" {
    var unit = gpt.Gpt.init();
    started(&unit);
    unit.write(base + gpt.periods.off.gtpbr, 4, 0x1000);
    var spins: u32 = 0;
    while (spins < 2) : (spins += 1) unit.tick();
    try testing.expect(unit.channels[0].period.loads >= 1);
    try testing.expectEqual(@as(u32, 0), unit.channels[0].period.changes);
}

test "a zero GTPR still counts to the 16-bit wrap" {
    var pair = period.Period{};
    try testing.expectEqual(period.default, pair.span());
    pair.set(.live, 0x40);
    try testing.expectEqual(@as(u32, 0x40), pair.span());
}

test "the pair owns its two offsets and nothing else" {
    try testing.expectEqual(period.Which.live, period.which(period.off.gtpr).?);
    try testing.expectEqual(period.Which.buffer, period.which(period.off.gtpbr + 3).?);
    try testing.expectEqual(@as(?period.Which, null), period.which(period.off.gtpbr + 4));
}

test "an untouched pair is quiet" {
    var pair = period.Period{};
    try testing.expect(pair.quiet());
    pair.set(.buffer, 0x10);
    try testing.expect(!pair.quiet());
}
