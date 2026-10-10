//! Covers src/chip/periph/byte_source.zig: a model reads through the function
//! the application paired with the context word.
const std = @import("std");
const ra8 = @import("ra8");
const ByteSource = ra8.chip.periph.byte_source.ByteSource;

/// Hands back `context` bytes of 'a', or null for nothing waiting at 0.
fn fill(context: usize, into: []u8) ?usize {
    if (context == 0) return null;
    const count = @min(context, into.len);
    @memset(into[0..count], 'a');
    return count;
}

test "a byte source reads through its function with its own context" {
    var bytes: [8]u8 = undefined;
    const three: ByteSource = .{ .context = 3, .readFn = fill };
    try std.testing.expectEqual(@as(?usize, 3), three.read(&bytes));
    try std.testing.expectEqualStrings("aaa", bytes[0..3]);
    const idle: ByteSource = .{ .context = 0, .readFn = fill };
    try std.testing.expectEqual(@as(?usize, null), idle.read(&bytes));
}
