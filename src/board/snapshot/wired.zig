//! The board's media and comms units whose wiring sits at the top level or
//! one field down, in a snapshot (RA8EMU-679): the CEU, the IPC mailbox, the
//! modem, the RTT trace reader and both PDCTR power domains, as one `wired`
//! section.
//!
//! Not saved, because it is wiring: the CEU's guest store, frame source and
//! time base, the IPC attribution's PRCR pointer, the RTT guest store and
//! the PDCTR protection pointers. A load keeps the target's. The units whose
//! wiring sits inside channel arrays or hooks (SSIE, SPI, USB, the Ethernet
//! switch, the NPU) are a separate section.
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
    .{ .name = "capture", .skip = &.{ "memory", "source", "clock" } },
    .{ .name = "mailbox", .skip = &.{"attrib"} },
    .{ .name = "mailbox", .sub = "attrib", .skip = &.{"protection"} },
    .{ .name = "modem" },
    .{ .name = "trace", .skip = &.{"memory"} },
    .{ .name = "domains", .sub = "graphics", .skip = &.{"protection"} },
    .{ .name = "domains", .sub = "eswm", .skip = &.{"protection"} },
};

pub fn save(board: anytype, writer: anytype) !void {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try body(&counter.writer, board);
    try file.writeSectionHeader(writer, .wired, counter.fullCount());
    try body(writer, board);
}

fn body(writer: anytype, board: anytype) !void {
    inline for (parts) |part| try fields.writeExcept(writer, target(board, part).*, part.skip);
}

/// All or nothing: every part is read over a copy of itself, and the board
/// changes only once the whole section read cleanly.
pub fn load(board: anytype, bytes: []const u8) Error!void {
    const section = try file.Reader.find(bytes, .wired) orelse return Error.Missing;
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
