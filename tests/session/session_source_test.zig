//! `info line`: gdb's wording for an address with a line, with a directory
//! or an absolute name, and for one without.
const std = @import("std");
const ra8 = @import("ra8");

const commands = ra8.session.commands;
const session_source = ra8.session.session_source;
const unit = @import("dwarf_units.zig").unit;

// Directories "src"; files "main.c" in directory 1, "/abs/boot.s" in 0.
const tables = "src\x00\x00main.c\x00\x01\x00\x00/abs/boot.s\x00\x00\x00\x00\x00";
// set_address 0x1000; copy (line 1); advance_pc 2 ops (4 bytes); set_file 2;
// advance_line +6; copy (0x1004, line 7); advance_pc 1 op; end_sequence.
const program = [_]u8{ 0x00, 0x05, 0x02, 0x00, 0x10, 0x00, 0x00, 0x01, 0x02, 0x02, 0x04, 0x02, 0x03, 0x06, 0x01, 0x02, 0x01, 0x00, 0x01, 0x01 };

fn said(sections: ra8.session.dwarf_line.Sections, address: u32, expected: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try session_source.line(&out.writer, sections, address);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "info line names the file under its directory and the row's addresses" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try unit(&list, 4, 2, tables, &program);
    const sections = ra8.session.dwarf_line.Sections{ .line = list.items };
    try said(sections, 0x1002, "Line 1 of \"src/main.c\" starts at address 0x00001000 and ends at 0x00001004.\n");
    try said(sections, 0x1005, "Line 7 of \"/abs/boot.s\" starts at address 0x00001004 and ends at 0x00001006.\n");
    try said(sections, 0x1006, "No line number information available for address 0x00001006\n");
}

test "info line ends where the line changes, past rows on the same line" {
    // set_address 0x1000; copy (line 1); advance_pc 1 op; copy (0x1002, line
    // 1 again); advance_pc 1 op; advance_line +1; copy (0x1004, line 2);
    // advance_pc 1 op; end_sequence at 0x1006.
    const repeated = [_]u8{ 0x00, 0x05, 0x02, 0x00, 0x10, 0x00, 0x00, 0x01, 0x02, 0x01, 0x01, 0x02, 0x01, 0x03, 0x01, 0x01, 0x02, 0x01, 0x00, 0x01, 0x01 };
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try unit(&list, 4, 2, tables, &repeated);
    const sections = ra8.session.dwarf_line.Sections{ .line = list.items };
    try said(sections, 0x1000, "Line 1 of \"src/main.c\" starts at address 0x00001000 and ends at 0x00001004.\n");
    try said(sections, 0x1003, "Line 1 of \"src/main.c\" starts at address 0x00001002 and ends at 0x00001004.\n");
}

test "an image with no line table, or a damaged one, has no line to give" {
    try said(session_source.of(null), 0x22000000, "No line number information available for address 0x22000000\n");
    const damaged = [_]u8{ 0x40, 0, 0, 0, 4, 0 };
    try said(.{ .line = &damaged }, 0x10, "No line number information available for address 0x00000010\n");
}

test "info line takes one place" {
    const parsed = (try commands.parse("info line target+4")).?;
    try std.testing.expectEqualStrings("target+4", parsed.line);
    try std.testing.expectError(error.MissingArgument, commands.parse("info line"));
    try std.testing.expectError(error.ExtraArgument, commands.parse("info line a b"));
}

fn listed(reader: *std.Io.Reader, first: u32, last: u32, expected: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try session_source.lines(&out.writer, reader, first, last);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "list numbers the window's lines and stops where the source does" {
    var whole: std.Io.Reader = .fixed("a\nb\nc\nd\ne\n");
    try listed(&whole, 2, 3, "2\tb\n3\tc\n");
    var short: std.Io.Reader = .fixed("a\nb\nlast");
    try listed(&short, 1, 10, "1\ta\n2\tb\n3\tlast\n");
    var empty: std.Io.Reader = .fixed("");
    try listed(&empty, 1, 10, "");
}

test "list keeps the start of an overlong line and carries on after it" {
    const long = &@as([session_source.limits.line_bytes + 10:0]u8, @splat('x'));
    var source: std.Io.Reader = .fixed(long ++ "\nnext\n");
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try session_source.lines(&out.writer, &source, 1, 2);
    try std.testing.expect(std.mem.endsWith(u8, out.written(), "\n2\tnext\n"));
    try std.testing.expectEqual(session_source.limits.line_bytes + 3 + 7, out.written().len);
}

fn sourced(dir: std.Io.Dir, sections: ra8.session.dwarf_line.Sections, address: u32, expected: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try session_source.list(&out.writer, sections, std.testing.io, dir, address);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "list reads the line's file under its directory, or says it is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/main.c", .data = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n" });
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try unit(&list, 4, 2, tables, &program);
    const sections = ra8.session.dwarf_line.Sections{ .line = list.items };
    try sourced(tmp.dir, sections, 0x1000, "1\t1\n2\t2\n3\t3\n4\t4\n5\t5\n6\t6\n7\t7\n8\t8\n9\t9\n10\t10\n");
    try sourced(tmp.dir, sections, 0x1004, "7\t/abs/boot.s: No such file or directory.\n");
    try sourced(tmp.dir, sections, 0x2000, "No line number information available for address 0x00002000\n");
}

test "list takes an optional place" {
    try std.testing.expectEqual(@as(?[]const u8, null), (try commands.parse("list")).?.list);
    try std.testing.expectEqualStrings("reset", (try commands.parse("l reset")).?.list.?);
    try std.testing.expectError(error.ExtraArgument, commands.parse("list a b"));
}

test "a backtrace frame gets at FILE:LINE, and nothing without a line" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try unit(&list, 4, 2, tables, &program);
    const sections = ra8.session.dwarf_line.Sections{ .line = list.items };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try session_source.at(&out.writer, sections, 0x1002);
    try session_source.at(&out.writer, sections, 0x1005);
    try session_source.at(&out.writer, sections, 0x1006);
    try session_source.at(&out.writer, .{}, 0x1002);
    try std.testing.expectEqualStrings(" at src/main.c:1 at /abs/boot.s:7", out.written());
}
