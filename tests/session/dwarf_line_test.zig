//! .debug_line: units built by hand in version 4 and version 5 form, each
//! address looked up to its file and line, and damaged units refused.
const std = @import("std");
const ra8 = @import("ra8");

const dwarf_line = ra8.session.dwarf_line;

const unit = @import("dwarf_units.zig").unit;

// Directories "src"; files "main.c" in directory 1.
const tables_v4 = "src\x00\x00main.c\x00\x01\x00\x00\x00";
// set_address 0x1000; copy (line 1); advance_pc 2 ops; advance_line +2;
// copy (0x1004, line 3); special 33 (+1 op, +1 line: 0x1006, line 4);
// advance_pc 1 op; end_sequence at 0x1008.
const program_v4 = [_]u8{ 0x00, 0x05, 0x02, 0x00, 0x10, 0x00, 0x00, 0x01, 0x02, 0x02, 0x03, 0x02, 0x01, 33, 0x02, 0x01, 0x00, 0x01, 0x01 };

fn expectPlace(sections: dwarf_line.Sections, address: u32, directory: []const u8, name: []const u8, line: u32) !void {
    const place = (try dwarf_line.lookup(sections, address)).?;
    try std.testing.expectEqualStrings(directory, place.file.directory);
    try std.testing.expectEqualStrings(name, place.file.name);
    try std.testing.expectEqual(line, place.line);
}

test "a version 4 unit maps each address to the row at or below it" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try unit(&list, 4, 2, tables_v4, &program_v4);
    const sections = dwarf_line.Sections{ .line = list.items };
    try expectPlace(sections, 0x1000, "src", "main.c", 1);
    try expectPlace(sections, 0x1003, "src", "main.c", 1);
    try expectPlace(sections, 0x1004, "src", "main.c", 3);
    try expectPlace(sections, 0x1007, "src", "main.c", 4);
    try std.testing.expectEqual(@as(u32, 0x1006), (try dwarf_line.lookup(sections, 0x1007)).?.address);
    try std.testing.expect(try dwarf_line.lookup(sections, 0x1008) == null);
    try std.testing.expect(try dwarf_line.lookup(sections, 0x0ffe) == null);
}

test "a version 5 unit reads its paths through .debug_line_str and numbers from zero" {
    // Directories: line_strp "/build", "lib". Files: (path string,
    // directory data1) "a.zig" in 0, "b.zig" in 1.
    const tables = "\x01\x01\x1f\x02\x00\x00\x00\x00\x07\x00\x00\x00" ++
        "\x02\x01\x08\x02\x0b\x02a.zig\x00\x00b.zig\x00\x01";
    // set_address 0x2000; set_file 1; advance_line +9; copy (line 10);
    // advance_pc 6; end_sequence at 0x2006.
    const program = [_]u8{ 0x00, 0x05, 0x02, 0x00, 0x20, 0x00, 0x00, 0x04, 0x01, 0x03, 0x09, 0x01, 0x02, 0x06, 0x00, 0x01, 0x01 };
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try unit(&list, 5, 1, tables, &program);
    const sections = dwarf_line.Sections{ .line = list.items, .strings = .{ .line_str = "/build\x00lib\x00" } };
    try expectPlace(sections, 0x2004, "lib", "b.zig", 10);
    try std.testing.expect(try dwarf_line.lookup(sections, 0x2006) == null);
}

test "a lookup walks past units that do not cover the address" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try unit(&list, 4, 2, tables_v4, &program_v4);
    var moved = program_v4;
    moved[4] = 0x30;
    try unit(&list, 4, 2, "\x00later.c\x00\x00\x00\x00\x00", &moved);
    try expectPlace(.{ .line = list.items }, 0x3004, "", "later.c", 3);
    try expectPlace(.{ .line = list.items }, 0x1004, "src", "main.c", 3);
}

test "64-bit DWARF is refused and a truncated unit is caught" {
    const wide = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0x10, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectError(error.Unsupported, dwarf_line.lookup(.{ .line = &wide }, 0));
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try unit(&list, 4, 2, tables_v4, &program_v4);
    try std.testing.expectError(error.Truncated, dwarf_line.lookup(.{ .line = list.items[0 .. list.items.len - 3] }, 0x1000));
}

test "the LEB128 reader takes multi-byte and negative values" {
    var cursor = ra8.session.dwarf_cursor.Cursor{ .bytes = &.{ 0xe5, 0x8e, 0x26, 0x7f, 0x80, 0x7f } };
    try std.testing.expectEqual(@as(u64, 624485), try cursor.uleb());
    try std.testing.expectEqual(@as(i64, -1), try cursor.sleb());
    try std.testing.expectEqual(@as(i64, -128), try cursor.sleb());
    try std.testing.expectError(error.Truncated, cursor.byte());
}
