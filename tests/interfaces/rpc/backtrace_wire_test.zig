//! Tests for src/interfaces/rpc/backtrace_wire.zig (RA8EMU-1125): packed
//! frames read back in order with their names and files, the widest frame
//! fits its length byte and frame_bytes, and a cut-off list is caught.
const std = @import("std");
const ra8 = @import("ra8");

const proto = ra8.rpc.session.rpc;
const backtrace_wire = ra8.rpc.backtrace_wire;

const long_name: [proto.frame_name_cap]u8 = @splat('n');
const long_file: [proto.frame_file_cap]u8 = @splat('f');
const widest: proto.StackFrame = .{
    .pc = 0xFFFF_FFFF,
    .interrupted = 1,
    .offset = 0xFFFF_FFFF,
    .line = 0xFFFF_FFFF,
    .name = &long_name,
    .file = &long_file,
};

test "packed frames read back in order" {
    var out: [proto.backtrace_bytes]u8 = undefined;
    var at: usize = 0;
    try backtrace_wire.put(&out, &at, .{ .pc = 0x100, .interrupted = 0, .offset = 0, .line = 12, .name = "main", .file = "main.c" });
    try backtrace_wire.put(&out, &at, .{ .pc = 0x200, .interrupted = 1, .offset = 6, .line = 0, .name = "", .file = "" });
    var reader: backtrace_wire.Reader = .{ .rest = out[0..at] };
    const first = (try reader.next()).?;
    try std.testing.expectEqual(@as(u32, 0x100), first.pc);
    try std.testing.expectEqualStrings("main", first.name);
    try std.testing.expectEqualStrings("main.c", first.file);
    try std.testing.expectEqual(@as(u32, 12), first.line);
    const second = (try reader.next()).?;
    try std.testing.expectEqual(@as(u8, 1), second.interrupted);
    try std.testing.expectEqual(@as(u32, 6), second.offset);
    try std.testing.expectEqual(@as(usize, 0), second.name.len);
    try std.testing.expectEqual(@as(?proto.StackFrame, null), try reader.next());
}

test "a full chain of the widest frames fits backtrace_bytes" {
    var out: [proto.backtrace_bytes]u8 = undefined;
    var at: usize = 0;
    for (0..proto.backtrace_frames) |_| try backtrace_wire.put(&out, &at, widest);
    try std.testing.expectEqual(proto.backtrace_bytes, at);
    try std.testing.expect(proto.frame_bytes - 1 <= std.math.maxInt(u8));
    try std.testing.expectError(error.Oversize, backtrace_wire.put(&out, &at, widest));
}

test "a list cut short is truncated" {
    var out: [proto.frame_bytes]u8 = undefined;
    var at: usize = 0;
    try backtrace_wire.put(&out, &at, widest);
    var reader: backtrace_wire.Reader = .{ .rest = out[0 .. at - 1] };
    try std.testing.expectError(error.Truncated, reader.next());
}
