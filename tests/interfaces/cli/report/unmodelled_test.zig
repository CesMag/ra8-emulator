//! Covers src/interfaces/cli/report/unmodelled.zig: the unmodelled addresses
//! the end-of-run report names, lowest first, capped at the limit.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const report_unmodelled = cli_app.report_unmodelled;
const Bus = ra8.chip.periph.registry.Bus;

test "lists unmodelled addresses lowest first with how they were touched" {
    var bus = Bus.init(std.testing.allocator);
    defer bus.deinit();
    bus.write(0x4000_0200, 4, 1);
    _ = bus.read(0x4000_0100, 4);
    bus.write(0x5000_0300, 2, 7);
    var buffer: [report_unmodelled.limit]report_unmodelled.Entry = undefined;
    const shown = report_unmodelled.lowest(&bus, &buffer);
    try std.testing.expectEqual(@as(usize, 3), shown.len);
    try std.testing.expectEqual(@as(u32, 0x4000_0100), shown[0].address);
    try std.testing.expect(!shown[0].written);
    try std.testing.expectEqual(@as(u32, 0x4000_0200), shown[1].address);
    try std.testing.expect(shown[1].written);
    try std.testing.expectEqual(@as(u32, 0x4000_0300), shown[2].address);
}

test "keeps only the lowest addresses once the buffer is full" {
    var bus = Bus.init(std.testing.allocator);
    defer bus.deinit();
    var address: u32 = 0x4000_0040;
    while (address > 0x4000_0000) : (address -= 4) bus.write(address, 4, 0);
    var buffer: [3]report_unmodelled.Entry = undefined;
    const shown = report_unmodelled.lowest(&bus, &buffer);
    try std.testing.expectEqual(@as(usize, 3), shown.len);
    try std.testing.expectEqual(@as(u32, 0x4000_0004), shown[0].address);
    try std.testing.expectEqual(@as(u32, 0x4000_0008), shown[1].address);
    try std.testing.expectEqual(@as(u32, 0x4000_000C), shown[2].address);
}

test "the section names each address and counts the rest" {
    var bus = Bus.init(std.testing.allocator);
    defer bus.deinit();
    var index: u32 = 0;
    while (index < report_unmodelled.limit + 2) : (index += 1) bus.write(0x4000_1000 + index * 4, 4, 0);
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    try report_unmodelled.section(&bus, &text.writer);
    try std.testing.expect(std.mem.startsWith(u8, text.written(), "unmodelled: 0x40001000 written\n"));
    try std.testing.expect(std.mem.endsWith(u8, text.written(), "unmodelled: 2 more not listed\n"));
}

test "an empty bus reports nothing" {
    var bus = Bus.init(std.testing.allocator);
    defer bus.deinit();
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    try report_unmodelled.section(&bus, &text.writer);
    try std.testing.expectEqual(@as(usize, 0), text.written().len);
}
