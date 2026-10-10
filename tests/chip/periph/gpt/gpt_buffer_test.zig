//! Covers src/chip/periph/gpt/gpt_buffer.zig: GTBER's single-buffer transfer, and the
//! duty the HAL parks in GTCCR[2] arriving on the next cycle.
const std = @import("std");
const testing = std.testing;

const ra8 = @import("ra8");
const buf = ra8.chip.periph.gpt_buffer;
const compare = ra8.chip.periph.gpt_compare;
const gpt = ra8.chip.periph.gpt;
const md = ra8.chip.periph.gpt_mode;

const ch0 = gpt.win_base;

/// A GTCR word carrying a mode encoding and the start bit.
fn control(encoding: u32) u32 {
    return gpt.control.cst | (encoding << md.field.shift);
}

/// Run boundaries until `want` is set in GTST, or give up.
fn until(unit: *gpt.Gpt, want: u32, budget: usize) bool {
    for (0..budget) |_| {
        unit.tick();
        if (unit.read(ch0 + gpt.off.gtst, 4) & want != 0) return true;
    }
    return false;
}

test "a reset buffer set is empty and silent" {
    var set = buf.Buffers{};
    try testing.expect(set.quiet());
    try testing.expect(!set.single(.a));
    try testing.expect(!set.single(.b));
    try testing.expectEqual(@as(?u32, null), set.take(.a));
}

test "each side answers to its own GTBER bit" {
    var set = buf.Buffers{ .ber = buf.field.ccra_single };
    try testing.expect(set.single(.a));
    try testing.expect(!set.single(.b));
    set.ber = buf.field.ccrb_single;
    try testing.expect(!set.single(.a));
    try testing.expect(set.single(.b));
}

test "an enabled side hands its value over and counts the transfer" {
    var set = buf.Buffers{ .ber = buf.field.ccra_single };
    set.set(.a, 0x1234);
    try testing.expectEqual(@as(?u32, 0x1234), set.take(.a));
    try testing.expectEqual(@as(u32, 1), set.reloads);
    try testing.expect(!set.quiet());
}

test "a disabled side hands nothing over and counts nothing" {
    var set = buf.Buffers{};
    set.set(.b, 0x99);
    try testing.expectEqual(@as(?u32, null), set.take(.b));
    try testing.expectEqual(@as(u32, 0), set.reloads);
}

test "the two buffers keep their own values" {
    var set = buf.Buffers{ .ber = buf.field.ccra_single | buf.field.ccrb_single };
    set.set(.a, 7);
    set.set(.b, 9);
    try testing.expectEqual(@as(?u32, 7), set.take(.a));
    try testing.expectEqual(@as(?u32, 9), set.take(.b));
}

test "double buffering falls back to the single transfer rather than guessing" {
    const upper = buf.field.ccra & ~buf.field.ccra_single;
    var set = buf.Buffers{ .ber = upper };
    try testing.expect(!set.single(.a));
}

test "only the two buffer words belong to this file" {
    try testing.expectEqual(buf.Side.a, buf.which(buf.off.buffer_a).?);
    try testing.expectEqual(buf.Side.a, buf.which(buf.off.buffer_a + 3).?);
    try testing.expectEqual(buf.Side.b, buf.which(buf.off.buffer_b).?);
    try testing.expectEqual(@as(?buf.Side, null), buf.which(compare.off.gtccra));
    try testing.expectEqual(@as(?buf.Side, null), buf.which(0x5C));
}

test "GTBER and both buffers read back what was written" {
    var unit = gpt.Gpt.init();
    unit.write(ch0 + buf.off.gtber, 4, buf.field.ccra_single);
    unit.write(ch0 + buf.off.buffer_a, 4, 0xDEAD);
    unit.write(ch0 + buf.off.buffer_b, 4, 0xBEEF);
    try testing.expectEqual(buf.field.ccra_single, unit.read(ch0 + buf.off.gtber, 4));
    try testing.expectEqual(@as(u32, 0xDEAD), unit.read(ch0 + buf.off.buffer_a, 4));
    try testing.expectEqual(@as(u32, 0xBEEF), unit.read(ch0 + buf.off.buffer_b, 4));
}

test "a parked compare does not disturb the live one before the cycle ends" {
    var unit = gpt.Gpt.init();
    unit.write(ch0 + compare.off.gtccra, 4, 0x1000);
    unit.write(ch0 + buf.off.buffer_a, 4, 0x2000);
    unit.write(ch0 + buf.off.gtber, 4, buf.field.ccra_single);
    unit.write(ch0 + gpt.off.gtpr, 4, 0xFFFF_FFFF);
    unit.write(ch0 + gpt.off.gtstr, 4, 1);
    unit.tick();
    try testing.expectEqual(@as(u32, 0x1000), unit.read(ch0 + compare.off.gtccra, 4));
}

test "a saw takes the parked compare up at its wrap" {
    var unit = gpt.Gpt.init();
    unit.write(ch0 + compare.off.gtccra, 4, 0x1000);
    unit.write(ch0 + buf.off.buffer_a, 4, 0x2000);
    unit.write(ch0 + buf.off.gtber, 4, buf.field.ccra_single);
    unit.write(ch0 + gpt.off.gtpr, 4, 0x4000);
    unit.write(ch0 + gpt.off.gtstr, 4, 1);
    try testing.expect(until(&unit, gpt.status.tcfpo, 8));
    try testing.expectEqual(@as(u32, 0x2000), unit.read(ch0 + compare.off.gtccra, 4));
}

test "a compare nobody buffered stays where firmware put it" {
    var unit = gpt.Gpt.init();
    unit.write(ch0 + compare.off.gtccrb, 4, 0x1000);
    unit.write(ch0 + buf.off.buffer_b, 4, 0x2000);
    unit.write(ch0 + gpt.off.gtpr, 4, 0x4000);
    unit.write(ch0 + gpt.off.gtstr, 4, 1);
    try testing.expect(until(&unit, gpt.status.tcfpo, 8));
    try testing.expectEqual(@as(u32, 0x1000), unit.read(ch0 + compare.off.gtccrb, 4));
}

test "a triangle reloads at the trough, not at the peak" {
    var unit = gpt.Gpt.init();
    unit.write(ch0 + compare.off.gtccra, 4, 0x1000);
    unit.write(ch0 + buf.off.buffer_a, 4, 0x2000);
    unit.write(ch0 + buf.off.gtber, 4, buf.field.ccra_single);
    unit.write(ch0 + gpt.off.gtpr, 4, 0x8000);
    unit.write(ch0 + gpt.off.gtcr, 4, control(4));
    try testing.expect(until(&unit, gpt.status.tcfpo, 16));
    try testing.expectEqual(@as(u32, 0x1000), unit.read(ch0 + compare.off.gtccra, 4));
    try testing.expect(until(&unit, gpt.status.tcfpu, 16));
    try testing.expectEqual(@as(u32, 0x2000), unit.read(ch0 + compare.off.gtccra, 4));
}

test "a reloaded compare is the one the next cycle matches against" {
    var unit = gpt.Gpt.init();
    unit.write(ch0 + buf.off.buffer_a, 4, 0x2000);
    unit.write(ch0 + buf.off.gtber, 4, buf.field.ccra_single);
    unit.write(ch0 + gpt.off.gtpr, 4, 0x4000);
    unit.write(ch0 + gpt.off.gtstr, 4, 1);
    unit.tick();
    // GTCCRA was zero, which is unarmed, so nothing can have matched yet.
    try testing.expectEqual(@as(u32, 0), unit.read(ch0 + gpt.off.gtst, 4) & gpt.status.tcfa);
    try testing.expect(until(&unit, gpt.status.tcfa, 16));
    try testing.expectEqual(@as(u32, 0x2000), unit.read(ch0 + compare.off.gtccra, 4));
}

test "a channel that only parked a duty is not quiet" {
    var unit = gpt.Gpt.init();
    try testing.expect(unit.quiet());
    unit.write(ch0 + buf.off.gtber, 4, buf.field.ccra_single);
    try testing.expect(!unit.quiet());
}

test "a narrow store lands on GTBER's own lane" {
    var unit = gpt.Gpt.init();
    unit.write(ch0 + buf.off.gtber + 2, 1, 0x05);
    try testing.expectEqual(@as(u32, 0x0005_0000), unit.read(ch0 + buf.off.gtber, 4));
    try testing.expect(unit.read(ch0 + buf.off.gtber, 4) & buf.field.ccra_single != 0);
}
