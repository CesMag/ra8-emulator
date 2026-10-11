//! Function bounds from .debug_info: low_pc with a length or an end
//! address, decl_line in any constant form, units in DWARF 4 and 5.
const std = @import("std");
const ra8 = @import("ra8");

const info = ra8.session.dwarf_info;

// 1: compile_unit with children, name as a string. 2: subprogram, low_pc
// addr, high_pc data4 (a length), decl_line data1, external flag_present.
// 3: subprogram, low_pc addr, high_pc addr, decl_line data2.
const abbrev = [_]u8{
    0x01, 0x11, 0x01, 0x03, 0x08, 0x00, 0x00,
    0x02, 0x2e, 0x00, 0x11, 0x01, 0x12, 0x06,
    0x3b, 0x0b, 0x3f, 0x19, 0x00, 0x00, 0x03,
    0x2e, 0x00, 0x11, 0x01, 0x12, 0x01, 0x3b,
    0x05, 0x00, 0x00, 0x00,
};

// The DIEs: "a.c"; 0x1000 for 0x20 bytes on line 7; 0x2000 to 0x2010 on
// line 300; the end of the unit's children.
const dies = [_]u8{
    0x01, 'a',  '.',  'c',  0x00,
    0x02, 0x00, 0x10, 0x00, 0x00,
    0x20, 0x00, 0x00, 0x00, 0x07,
    0x03, 0x00, 0x20, 0x00, 0x00,
    0x10, 0x20, 0x00, 0x00, 0x2c,
    0x01, 0x00,
};

fn unit(list: *std.Io.Writer, version: u16) !void {
    const head: u32 = if (version >= 5) 8 else 7;
    try list.writeInt(u32, head + @as(u32, dies.len), .little);
    try list.writeInt(u16, version, .little);
    if (version >= 5) try list.writeAll(&.{ 0x01, 0x04 });
    try list.writeInt(u32, 0, .little);
    if (version < 5) try list.writeByte(0x04);
    try list.writeAll(&dies);
}

fn expectFunction(sections: info.Sections, address: u32, low: u32, high: u32, line: u32) !void {
    const found = (try info.containing(sections, address)).?;
    try std.testing.expectEqual(info.Function{ .low = low, .high = high, .decl_line = line }, found);
}

test "a DWARF 4 subprogram's bounds come from a length or an end address" {
    var list: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer list.deinit();
    try unit(&list.writer, 4);
    const sections = info.Sections{ .info = list.written(), .abbrev = &abbrev };
    try expectFunction(sections, 0x1000, 0x1000, 0x1020, 7);
    try expectFunction(sections, 0x101F, 0x1000, 0x1020, 7);
    try expectFunction(sections, 0x2008, 0x2000, 0x2010, 300);
    try std.testing.expectEqual(@as(?info.Function, null), try info.containing(sections, 0x1020));
    try std.testing.expectEqual(@as(?info.Function, null), try info.containing(sections, 0x0FFF));
}

test "a DWARF 5 unit reads the same, after a second unit is skipped past" {
    var list: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer list.deinit();
    try unit(&list.writer, 4);
    try unit(&list.writer, 5);
    const sections = info.Sections{ .info = list.written(), .abbrev = &abbrev };
    try expectFunction(sections, 0x2000, 0x2000, 0x2010, 300);
}

test "no sections means no function, and 64-bit DWARF is refused" {
    try std.testing.expectEqual(@as(?info.Function, null), try info.containing(.{}, 0x1000));
    const wide = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00 };
    try std.testing.expectError(error.Unsupported, info.containing(.{ .info = &wide, .abbrev = &abbrev }, 0));
}
