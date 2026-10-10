//! The board's security and system control units in a snapshot
//! (RA8EMU-671): PSCU, the DTC SAR, CPSCU and its SRAM words, SAMON, the
//! IDAU, CPU control, the reset causes and SYRSTMSK, SCB AIRCR, the fault
//! status clears, the cache unit, both MPUs, the MPU guard's fault latch
//! and the SAU, as one `security` section.
//!
//! Not saved, because it is wiring: the protection pointers, the IDAU's
//! SRAM unit and bank table (chosen by part), SYRSTMSK's protection and
//! armed-flag pointers, and the MPU guard's unit pointer, engine hooks and
//! live hook count. A load keeps the target's.
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

/// Format order. Appending is a format change. A `sub` part comes after
/// its parent, which skips it, so loading the parent cannot undo it.
const parts = [_]Part{
    .{ .name = "attribution" },
    .{ .name = "transfer_attribution", .skip = &.{"protection"} },
    .{ .name = "chip_attribution", .skip = &.{"protection"} },
    .{ .name = "sram_attribution" },
    .{ .name = "memory_monitors" },
    .{ .name = "idau", .skip = &.{ "sram", "banks" } },
    .{ .name = "second_core" },
    .{ .name = "causes", .skip = &.{"masks"} },
    .{ .name = "causes", .sub = "masks", .skip = &.{ "protection", "watchdog_armed", "heartbeat_armed" } },
    .{ .name = "control" },
    .{ .name = "clears" },
    .{ .name = "caches" },
    .{ .name = "regions" },
    .{ .name = "regions_ns" },
    .{ .name = "guard", .skip = &.{ "unit", "hooks", "live" } },
    .{ .name = "partitions" },
};

pub fn save(board: anytype, writer: anytype) !void {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try body(&counter.writer, board);
    try file.writeSectionHeader(writer, .security, counter.fullCount());
    try body(writer, board);
}

fn body(writer: anytype, board: anytype) !void {
    inline for (parts) |part| try fields.writeExcept(writer, target(board, part).*, part.skip);
}

/// All or nothing: every part is read over a copy of itself, and the board
/// changes only once the whole section read cleanly and every region
/// select lands inside its table.
pub fn load(board: anytype, bytes: []const u8) Error!void {
    const section = try file.Reader.find(bytes, .security) orelse return Error.Missing;
    var cursor: fields.Cursor = .{ .bytes = section.payload };
    var copies: Copies(@TypeOf(board)) = undefined;
    inline for (parts, 0..) |part, i| {
        copies[i] = target(board, part).*;
        try fields.readOver(&cursor, &copies[i], part.skip);
    }
    if (!cursor.done() or !fits(&copies)) return Error.BadValue;
    inline for (parts, 0..) |part, i| target(board, part).* = copies[i];
}

fn fits(copies: anytype) bool {
    inline for (parts, 0..) |part, i| {
        const one = copies[i];
        if (comptime isTable(part.name)) {
            if (one.selected >= one.table.len) return false;
        }
    }
    return true;
}

fn isTable(comptime name: []const u8) bool {
    const tables = [_][]const u8{ "regions", "regions_ns", "partitions" };
    inline for (tables) |one| if (std.mem.eql(u8, name, one)) return true;
    return false;
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
