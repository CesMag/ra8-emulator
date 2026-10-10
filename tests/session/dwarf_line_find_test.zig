//! FILE:LINE to an address: name matching, the lowest address on a line,
//! and a line with no code falling through to the next one that has some.
const std = @import("std");
const ra8 = @import("ra8");

const find = ra8.session.dwarf_line_find;
const session_source = ra8.session.source;
const unit = @import("dwarf_units.zig").unit;

// Directories "src"; files "main.c" in directory 1, "/abs/boot.s" in 0.
const tables = "src\x00\x00main.c\x00\x01\x00\x00/abs/boot.s\x00\x00\x00\x00\x00";
// set_address 0x1000; advance_line +2; copy (0x1000, main.c:3); advance_pc
// 1 op; advance_line +2; copy (0x1002, line 5); advance_pc 1 op;
// advance_line -2; copy (0x1004, line 3 again); set_file 2; advance_pc 1
// op; copy (0x1006, boot.s:3); advance_pc 1 op; end_sequence at 0x1008.
const program = [_]u8{ 0x00, 0x05, 0x02, 0x00, 0x10, 0x00, 0x00, 0x03, 0x02, 0x01, 0x02, 0x01, 0x03, 0x02, 0x01, 0x02, 0x01, 0x03, 0x7e, 0x01, 0x04, 0x02, 0x02, 0x01, 0x01, 0x02, 0x01, 0x00, 0x01, 0x01 };

fn sections(list: *std.ArrayList(u8)) !ra8.session.dwarf_line.Sections {
    try unit(list, 4, 2, tables, &program);
    return .{ .line = list.items };
}

test "a line's lowest address wins, in the file asked for" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    const s = try sections(&list);
    try std.testing.expectEqual(@as(?u32, 0x1000), try find.addressOf(s, "main.c", 3));
    try std.testing.expectEqual(@as(?u32, 0x1002), try find.addressOf(s, "main.c", 5));
    try std.testing.expectEqual(@as(?u32, 0x1006), try find.addressOf(s, "boot.s", 3));
}

test "a line without code falls to the next one, and past the last is none" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    const s = try sections(&list);
    try std.testing.expectEqual(@as(?u32, 0x1002), try find.addressOf(s, "main.c", 4));
    try std.testing.expectEqual(@as(?u32, 0x1000), try find.addressOf(s, "main.c", 1));
    try std.testing.expectEqual(@as(?u32, null), try find.addressOf(s, "main.c", 6));
    try std.testing.expectEqual(@as(?u32, null), try find.addressOf(s, "other.c", 3));
}

test "a file is found by name, path tail or whole path, never a partial name" {
    const relative = ra8.session.dwarf_line.File{ .directory = "src", .name = "main.c" };
    try std.testing.expect(find.named(relative, "main.c"));
    try std.testing.expect(find.named(relative, "src/main.c"));
    try std.testing.expect(!find.named(relative, "ain.c"));
    try std.testing.expect(!find.named(relative, "lib/main.c"));
    const absolute = ra8.session.dwarf_line.File{ .directory = "src", .name = "/abs/boot.s" };
    try std.testing.expect(find.named(absolute, "boot.s"));
    try std.testing.expect(find.named(absolute, "abs/boot.s"));
    try std.testing.expect(find.named(absolute, "/abs/boot.s"));
    try std.testing.expect(!find.named(absolute, "src/boot.s"));
}

test "FILE:LINE is told apart from the other places" {
    const at = session_source.fileLine("fw.zig:8").?;
    try std.testing.expectEqualStrings("fw.zig", at.file);
    try std.testing.expectEqual(@as(u32, 8), at.line);
    try std.testing.expectEqual(@as(?session_source.FileLine, null), session_source.fileLine("target+4"));
    try std.testing.expectEqual(@as(?session_source.FileLine, null), session_source.fileLine(":8"));
    try std.testing.expectEqual(@as(?session_source.FileLine, null), session_source.fileLine("fw.zig:0"));
    try std.testing.expectEqual(@as(?session_source.FileLine, null), session_source.fileLine("fw.zig:x"));
}

// Directory none; file "a.c". set_address 0x1000; advance_line +2; copy
// (0x1000, line 3); advance_pc 1 op; advance_line +1; set_prologue_end;
// copy (0x1002, line 4); advance_pc 1 op; end_sequence at 0x1004.
const entry_tables = "\x00a.c\x00\x00\x00\x00\x00";
const entry_program = [_]u8{ 0x00, 0x05, 0x02, 0x00, 0x10, 0x00, 0x00, 0x03, 0x02, 0x01, 0x02, 0x01, 0x03, 0x01, 0x0a, 0x01, 0x02, 0x01, 0x00, 0x01, 0x01 };

test "a break on a function's entry moves past the prologue, or is refused before its declaration" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try unit(&list, 4, 2, entry_tables, &entry_program);
    const s = ra8.session.dwarf_line.Sections{ .line = list.items };
    try std.testing.expectEqual(@as(?u32, 0x1002), try find.prologueEnd(s, 0x1000, 0x1004));
    try std.testing.expectEqual(@as(?u32, null), try find.prologueEnd(s, 0x1003, 0x1004));
    const function = ra8.session.dwarf_info.Function{ .low = 0x1000, .high = 0x1004, .decl_line = 2 };
    try std.testing.expectEqual(@as(?u32, 0x1002), session_source.settle(s, 0x1000, function, 2));
    try std.testing.expectEqual(@as(?u32, null), session_source.settle(s, 0x1000, function, 1));
    try std.testing.expectEqual(@as(?u32, 0x1002), session_source.settle(s, 0x1002, function, 4));
    try std.testing.expectEqual(@as(?u32, 0x1000), session_source.settle(s, 0x1000, null, 1));
}

test {
    _ = @import("dwarf_info_test.zig");
}
