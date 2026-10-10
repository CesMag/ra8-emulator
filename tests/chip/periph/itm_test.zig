//! The ITM stimulus ports, their enables, and the text port 0 collects.
const std = @import("std");
const ra8 = @import("ra8");
const itm = ra8.chip.periph.itm;

fn enabled() itm.Itm {
    var unit = itm.Itm{};
    _ = unit.write(itm.offsets.tcr, itm.tcr_bits.itmena, 4);
    _ = unit.write(itm.offsets.ter, 0xFFFF_FFFF, 4);
    return unit;
}

test "stimulus ports read FIFOREADY and the controls read back" {
    var unit = enabled();
    try std.testing.expectEqual(@as(?u32, itm.fifo_ready), unit.peek(itm.offsets.stim0));
    try std.testing.expectEqual(@as(?u32, itm.fifo_ready), unit.peek(31 * 4));
    try std.testing.expectEqual(@as(?u32, null), unit.peek(32 * 4));
    try std.testing.expectEqual(@as(?u32, null), unit.peek(2));
    try std.testing.expectEqual(@as(?u32, 0xFFFF_FFFF), unit.peek(itm.offsets.ter));
    _ = unit.write(itm.offsets.tcr, itm.tcr_bits.itmena | itm.tcr_bits.busy, 4);
    try std.testing.expectEqual(@as(?u32, itm.tcr_bits.itmena), unit.peek(itm.offsets.tcr));
    try std.testing.expect(!unit.write(0x100, 1, 4));
}

test "port 0 keeps the bytes each store carries" {
    var unit = enabled();
    _ = unit.write(itm.offsets.stim0, 'H', 1);
    _ = unit.write(itm.offsets.stim0, 'i' | (@as(u32, '!') << 8), 2);
    _ = unit.write(itm.offsets.stim0, 0x0A, 1);
    try std.testing.expectEqualStrings("Hi!\n", unit.output());
    unit.clear();
    try std.testing.expectEqualStrings("", unit.output());
}

test "nothing is kept with ITMENA clear or the port disabled" {
    var unit = itm.Itm{};
    _ = unit.write(itm.offsets.ter, 1, 4);
    _ = unit.write(itm.offsets.stim0, 'x', 1);
    _ = unit.write(itm.offsets.tcr, itm.tcr_bits.itmena, 4);
    _ = unit.write(itm.offsets.ter, 0b10, 4);
    _ = unit.write(itm.offsets.stim0, 'y', 1);
    _ = unit.write(4, 'z', 1);
    try std.testing.expectEqualStrings("", unit.output());
    try std.testing.expectEqual(@as(usize, 1), unit.other_ports);
}

test "text past the capacity is counted as dropped" {
    var unit = enabled();
    for (0..itm.limits.capacity + 3) |_| _ = unit.write(itm.offsets.stim0, '.', 1);
    try std.testing.expectEqual(itm.limits.capacity, unit.output().len);
    try std.testing.expectEqual(@as(usize, 3), unit.dropped);
}

fn sent(unit: *itm.Itm, text: []const u8) void {
    for (text) |byte| _ = unit.write(itm.offsets.stim0, byte, 1);
}

test "flush writes complete lines and keeps the unfinished one" {
    var unit = enabled();
    sent(&unit, "boot ok\r\nticks=3\nhalf");
    var buffer: [128]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buffer);
    try unit.flush(&stream, false);
    try std.testing.expectEqualStrings("itm: boot ok\nitm: ticks=3\n", stream.buffered());
    try std.testing.expectEqualStrings("half", unit.output());
    sent(&unit, " done");
    stream.end = 0;
    try unit.flush(&stream, true);
    try std.testing.expectEqualStrings("itm: half done\n", stream.buffered());
    try std.testing.expectEqualStrings("", unit.output());
}

test "flush says how much was dropped and writes a full line out" {
    var unit = enabled();
    for (0..itm.limits.capacity + 2) |_| _ = unit.write(itm.offsets.stim0, 'a', 1);
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try unit.flush(&counter.writer, false);
    try std.testing.expectEqual(@as(u64, itm.limits.capacity + 6 + "itm: (2 characters dropped)\n".len), counter.fullCount());
    try std.testing.expectEqual(@as(usize, 0), unit.output().len);
    try std.testing.expectEqual(@as(usize, 0), unit.dropped);
}
