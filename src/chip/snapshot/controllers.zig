//! The board's fixed-size memory controllers in a snapshot (RA8EMU-672):
//! the code-MRAM frequency latches and prefetch buffer, the MRAM ECC
//! controls, the SDRAM controller, the decryption-on-the-fly channels and
//! the SRAM controller's ECC side, as one `controllers` section.
//!
//! None of these units point at anything, so every field is saved. The
//! sparse parts (the option MRAM cells and the xSPI flash sectors) need a
//! variable-length encoding and are a separate section.
const std = @import("std");
const file = @import("ra8_snapshot").file;
const fields = @import("ra8_snapshot").fields;

pub const Error = file.Error || fields.Error || error{Missing};

/// Format order. Appending is a format change.
const parts = [_][]const u8{ "memory_rates", "memory_ecc", "sdram", "cipher", "ecc" };

const none: []const []const u8 = &.{};

pub fn save(board: anytype, writer: anytype) !void {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try body(&counter.writer, board);
    try file.writeSectionHeader(writer, .controllers, counter.fullCount());
    try body(writer, board);
}

fn body(writer: anytype, board: anytype) !void {
    inline for (parts) |name| try fields.writeExcept(writer, @field(board, name), none);
}

/// All or nothing: every part is read over a copy of itself, and the board
/// changes only once the whole section read cleanly.
pub fn load(board: anytype, bytes: []const u8) Error!void {
    const section = try file.Reader.find(bytes, .controllers) orelse return Error.Missing;
    var cursor: fields.Cursor = .{ .bytes = section.payload };
    var copies: Copies(@TypeOf(board)) = undefined;
    inline for (parts, 0..) |name, i| {
        copies[i] = @field(board, name);
        try fields.readOver(&cursor, &copies[i], none);
    }
    if (!cursor.done()) return Error.BadValue;
    inline for (parts, 0..) |name, i| @field(board, name) = copies[i];
}

/// The types of `parts` in `Board`, as a tuple.
fn Copies(comptime Board: type) type {
    const Child = @typeInfo(Board).pointer.child;
    var types: [parts.len]type = undefined;
    for (parts, 0..) |name, i| types[i] = @FieldType(Child, name);
    return @Tuple(&types);
}
