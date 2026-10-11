//! .debug_frame: finding the FDE for a pc, and running the CIE's and the
//! FDE's instructions to the row at that pc.
const std = @import("std");
const ra8 = @import("ra8");

const frame = ra8.session.dwarf.frame;

/// A version 4 CIE at offset 0 (code align 2, data align -4, return
/// address in r14, CFA = r13) and one FDE over 0x1000..0x1020.
fn build(list: *std.Io.Writer, cie_steps: []const u8, fde_steps: []const u8) !void {
    const cie_head = [_]u8{ 0xff, 0xff, 0xff, 0xff, 4, 0, 4, 0, 0x02, 0x7c, 0x0e };
    try entry(list, &cie_head, cie_steps);
    const fde_head = [_]u8{ 0, 0, 0, 0, 0x00, 0x10, 0, 0, 0x20, 0, 0, 0 };
    try entry(list, &fde_head, fde_steps);
}

fn entry(list: *std.Io.Writer, head: []const u8, program: []const u8) !void {
    try list.writeInt(u32, @intCast(head.len + program.len), .little);
    try list.writeAll(head);
    try list.writeAll(program);
}

const cie_program = [_]u8{ 0x0c, 0x0d, 0x00 };
// advance 1 (0x1002); cfa offset 8; lr at cfa-4; r4 at cfa-8; advance 2
// (0x1006); remember; cfa offset 16; advance 1 (0x1008); restore_state;
// restore r4.
const fde_program = [_]u8{ 0x41, 0x0e, 0x08, 0x8e, 0x01, 0x84, 0x02, 0x42, 0x0a, 0x0e, 0x10, 0x41, 0x0b, 0xc4 };

fn rowAt(bytes: []const u8, pc: u32) !frame.Row {
    const fde = (try frame.find(bytes, pc)).?;
    return frame.rowAt(fde, pc);
}

test "the FDE covering a pc is found, and none outside its range" {
    var list: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer list.deinit();
    try build(&list.writer, &cie_program, &fde_program);
    const fde = (try frame.find(list.written(), 0x101e)).?;
    try std.testing.expectEqual(@as(u32, 0x1000), fde.start);
    try std.testing.expectEqual(@as(u32, 0x1020), fde.end);
    try std.testing.expectEqual(@as(u64, 14), fde.cie.return_register);
    try std.testing.expectEqual(@as(?frame.Fde, null), try frame.find(list.written(), 0x1020));
    try std.testing.expectEqual(@as(?frame.Fde, null), try frame.find(list.written(), 0x0fff));
}

test "the row follows the program up to the pc and no further" {
    var list: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer list.deinit();
    try build(&list.writer, &cie_program, &fde_program);
    const entry_row = try rowAt(list.written(), 0x1000);
    try std.testing.expectEqual(frame.Cfa{ .register = 13, .offset = 0 }, entry_row.cfa);
    try std.testing.expectEqual(frame.Rule.same, entry_row.rules[14]);
    const pushed = try rowAt(list.written(), 0x1004);
    try std.testing.expectEqual(@as(i64, 8), pushed.cfa.offset);
    try std.testing.expectEqual(frame.Rule{ .offset = -4 }, pushed.rules[14]);
    try std.testing.expectEqual(frame.Rule{ .offset = -8 }, pushed.rules[4]);
    try std.testing.expectEqual(@as(i64, 16), (try rowAt(list.written(), 0x1006)).cfa.offset);
}

test "restore_state brings the remembered CFA back and restore the CIE's rule" {
    var list: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer list.deinit();
    try build(&list.writer, &cie_program, &fde_program);
    const after = try rowAt(list.written(), 0x1010);
    try std.testing.expectEqual(@as(i64, 8), after.cfa.offset);
    try std.testing.expectEqual(frame.Rule{ .offset = -4 }, after.rules[14]);
    try std.testing.expectEqual(frame.Rule.same, after.rules[4]);
}

test "expressions, unbalanced state and 64-bit DWARF are refused" {
    var expression: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer expression.deinit();
    try build(&expression.writer, &cie_program, &.{ 0x0f, 0x01, 0x30 });
    try std.testing.expectError(error.Unsupported, rowAt(expression.written(), 0x1000));
    var deep: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer deep.deinit();
    try build(&deep.writer, &cie_program, &.{ 0x0a, 0x0a, 0x0a, 0x0a, 0x0a });
    try std.testing.expectError(error.BadState, rowAt(deep.written(), 0x1000));
    var empty: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer empty.deinit();
    try build(&empty.writer, &cie_program, &.{0x0b});
    try std.testing.expectError(error.BadState, rowAt(empty.written(), 0x1000));
    const wide = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0 };
    try std.testing.expectError(error.Unsupported, frame.find(&wide, 0x1000));
}

test "a rule about a register past r15 is ignored, not refused" {
    var list: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer list.deinit();
    // offset_extended d8 (DWARF 264) at cfa-8, then lr at cfa-4.
    try build(&list.writer, &cie_program, &.{ 0x05, 0x88, 0x02, 0x02, 0x8e, 0x01 });
    const row = try rowAt(list.written(), 0x1000);
    try std.testing.expectEqual(frame.Rule{ .offset = -4 }, row.rules[14]);
}
