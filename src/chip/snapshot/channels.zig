//! The board's units whose wiring sits inside their channel arrays, in a
//! snapshot (RA8EMU-681): SSIE audio and SPI, as one `channels` section.
//!
//! Not saved, because it is wiring: each SSIE channel's audio tap listener
//! and each SPI channel's attached device. A load keeps the target's. USB,
//! the Ethernet switch and the NPU are separate sections.
const std = @import("std");
const file = @import("ra8_snapshot").file;
const fields = @import("ra8_snapshot").fields;

pub const Error = file.Error || fields.Error || error{Missing};

/// One board field (or one field of it) and the wiring it carries.
const Part = struct {
    name: []const u8,
    sub: ?[]const u8 = null,
    skip: []const []const u8 = &.{},
};

/// Format order. Appending is a format change.
const parts = [_]Part{
    .{ .name = "audio", .skip = &.{"channels.listener"} },
    .{ .name = "spi", .skip = &.{"channels.device"} },
};

pub fn save(board: anytype, writer: anytype) !void {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try body(&counter.writer, board);
    try file.writeSectionHeader(writer, .channels, counter.fullCount());
    try body(writer, board);
}

fn body(writer: anytype, board: anytype) !void {
    inline for (parts) |part| try fields.writeExcept(writer, target(board, part).*, part.skip);
}

/// All or nothing: every part is read over a copy of itself, and the board
/// changes only once the whole section read cleanly.
pub fn load(board: anytype, bytes: []const u8) Error!void {
    const section = try file.Reader.find(bytes, .channels) orelse return Error.Missing;
    var cursor: fields.Cursor = .{ .bytes = section.payload };
    var copies: Copies(@TypeOf(board)) = undefined;
    inline for (parts, 0..) |part, i| {
        copies[i] = target(board, part).*;
        try fields.readOver(&cursor, &copies[i], part.skip);
    }
    if (!cursor.done()) return Error.BadValue;
    inline for (parts, 0..) |part, i| target(board, part).* = copies[i];
}

fn Target(comptime Board: type, comptime part: Part) type {
    const Outer = @FieldType(@typeInfo(Board).pointer.child, part.name);
    return if (part.sub) |sub| @FieldType(Outer, sub) else Outer;
}

fn target(board: anytype, comptime part: Part) Pointer(@TypeOf(board), part) {
    const outer = &@field(board, part.name);
    return if (part.sub) |sub| &@field(outer, sub) else outer;
}

fn Pointer(comptime Board: type, comptime part: Part) type {
    const info = @typeInfo(Board).pointer;
    return if (info.attrs.@"const") *const Target(Board, part) else *Target(Board, part);
}

/// The types of `parts`' targets in `Board`, as a tuple.
fn Copies(comptime Board: type) type {
    var types: [parts.len]type = undefined;
    for (parts, 0..) |part, i| types[i] = Target(Board, part);
    return @Tuple(&types);
}
