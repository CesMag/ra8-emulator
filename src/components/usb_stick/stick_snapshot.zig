//! The MSC target's half of the `usb` snapshot section (RA8EMU-682,
//! RA8EMU-1104): the target's plain state, then its data and sink cursors.
//!
//! The cursors point into the disk, the target's scratch reply or the
//! constant INQUIRY data, so each goes as where it points, how far in and
//! how long, and is rebuilt over the target's own buffers. Not saved: `disk`
//! (a host attachment, like an SD image). A load is two steps, so the
//! board's section can read every half before it changes anything: `read`
//! gives a `Staged` target, and `install` puts it in place.
const fields = @import("ra8_snapshot").fields;
const stick = @import("stick.zig");
const Target = stick.Target;

const skip: []const []const u8 = &.{ "disk", "data", "sink" };

const Where = enum(u8) { none, disk, scratch, inquiry };

/// A cursor as where it points, how far in and how long.
const Span = struct { where: Where = .none, offset: u32 = 0, len: u32 = 0 };

/// `target` must be the live one: its cursors are found by address.
pub fn write(writer: anytype, target: *const Target) !void {
    try fields.writeExcept(writer, target.*, skip);
    try fields.write(writer, try locate(target, target.data));
    try fields.write(writer, try locate(target, target.sink));
}

/// A target read from a payload and not yet in place: the live target with
/// the saved fields read over it, and where its two cursors go.
pub const Staged = struct {
    target: Target,
    data: Span,
    sink: Span,

    /// Whether both cursors land inside the buffers the target has; the
    /// sink only ever points into the disk.
    pub fn fits(self: *const Staged) bool {
        if (!holds(&self.target, self.data)) return false;
        if (self.sink.where != .none and self.sink.where != .disk) return false;
        return holds(&self.target, self.sink);
    }

    /// Put this target in `live`'s place, its cursors over `live`'s own
    /// buffers.
    pub fn install(self: *const Staged, live: *Target) void {
        live.* = self.target;
        live.data = base(live, self.data.where)[self.data.offset..][0..self.data.len];
        live.sink = if (self.sink.where == .disk) live.disk[self.sink.offset..][0..self.sink.len] else &.{};
    }
};

pub fn read(cursor: *fields.Cursor, live: *const Target) fields.Error!Staged {
    var target = live.*;
    try fields.readOver(cursor, &target, skip);
    const data = try fields.read(Span, cursor);
    return .{ .target = target, .data = data, .sink = try fields.read(Span, cursor) };
}

fn base(target: *const Target, where: Where) []const u8 {
    return switch (where) {
        .none => &.{},
        .disk => target.disk,
        .scratch => &target.scratch,
        .inquiry => &stick.inquiry_data,
    };
}

fn locate(target: *const Target, cursor: []const u8) error{Stray}!Span {
    if (cursor.len == 0) return .{};
    const at = @intFromPtr(cursor.ptr);
    inline for (.{ Where.disk, Where.scratch, Where.inquiry }) |where| {
        const within = base(target, where);
        const lo = @intFromPtr(within.ptr);
        if (at >= lo and at + cursor.len <= lo + within.len)
            return .{ .where = where, .offset = @intCast(at - lo), .len = @intCast(cursor.len) };
    }
    return error.Stray;
}

fn holds(target: *const Target, span: Span) bool {
    if (span.where == .none) return span.offset == 0 and span.len == 0;
    const within = base(target, span.where);
    return span.len != 0 and span.offset <= within.len and span.len <= within.len - span.offset;
}
