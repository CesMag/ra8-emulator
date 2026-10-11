//! A small JSON writer for `--report json` (RA8EMU-347).
//!
//! std.json can serialise a struct by reflection, but then every field a
//! model grows lands in the document under whatever name the model gave it.
//! The report is a contract agents parse, so each section names its fields
//! here by hand and this writer only handles commas, nesting and escaping.
const std = @import("std");

/// The writer over any `out` with writeByte, writeAll and print.
pub fn Json(comptime W: type) type {
    return struct {
        const Self = @This();

        out: W,
        /// Bit d is set once nesting depth d has written an item, so the
        /// next item at that depth needs a comma first.
        written: u32 = 0,
        depth: u5 = 0,

        pub fn init(out: W) Self {
            return .{ .out = out };
        }

        fn item(self: *Self, key: ?[]const u8) !void {
            const bit = @as(u32, 1) << self.depth;
            if (self.written & bit != 0) try self.out.writeByte(',');
            self.written |= bit;
            if (key) |name| {
                try string(self.out, name);
                try self.out.writeByte(':');
            }
        }

        /// Open an object ('{') or array ('['), keyed when inside an object.
        pub fn open(self: *Self, key: ?[]const u8, bracket: u8) !void {
            if (self.depth == std.math.maxInt(u5)) return error.TooDeep;
            try self.item(key);
            try self.out.writeByte(bracket);
            self.depth += 1;
            self.written &= ~(@as(u32, 1) << self.depth);
        }

        /// Close what `open` opened; `bracket` is '}' or ']'.
        pub fn close(self: *Self, bracket: u8) !void {
            self.depth -= 1;
            try self.out.writeByte(bracket);
        }

        /// One scalar: a bool, an integer, a string, null or an optional.
        pub fn field(self: *Self, key: ?[]const u8, value: anytype) !void {
            try self.item(key);
            try scalar(self.out, value);
        }
    };
}

/// A writer over `out`, its type taken from the argument.
pub fn over(out: anytype) Json(@TypeOf(out)) {
    return Json(@TypeOf(out)).init(out);
}

fn scalar(out: anytype, value: anytype) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .bool => try out.writeAll(if (value) "true" else "false"),
        .int, .comptime_int => try out.print("{d}", .{value}),
        .null => try out.writeAll("null"),
        .optional => if (value) |inner| try scalar(out, inner) else try out.writeAll("null"),
        .pointer => try string(out, value),
        else => @compileError("json: no form for " ++ @typeName(T)),
    }
}

/// A quoted, escaped JSON string.
pub fn string(out: anytype, text: []const u8) !void {
    try out.writeByte('"');
    for (text) |c| switch (c) {
        '"' => try out.writeAll("\\\""),
        '\\' => try out.writeAll("\\\\"),
        '\n' => try out.writeAll("\\n"),
        0...9, 11...0x1f => try out.print("\\u{x:0>4}", .{c}),
        else => try out.writeByte(c),
    };
    try out.writeByte('"');
}
