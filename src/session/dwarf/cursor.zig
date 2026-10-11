//! A bounds-checked reader over one DWARF section's bytes.
//!
//! Every read either returns a value from inside `bytes` or fails with
//! `Truncated`, so a damaged or hostile section can never index past its
//! end. Integers are little-endian, as every Arm image this emulator loads.
const std = @import("std");

pub const Error = error{
    /// A read ran past the end of the bytes it was given.
    Truncated,
    /// Well-formed, but a shape this reader does not take (64-bit DWARF,
    /// an unknown form, a LEB128 wider than 64 bits).
    Unsupported,
};

pub const Cursor = struct {
    bytes: []const u8,
    /// Always at most `bytes.len`.
    at: usize = 0,

    pub fn done(self: *const Cursor) bool {
        return self.at >= self.bytes.len;
    }

    pub fn byte(self: *Cursor) Error!u8 {
        if (self.at >= self.bytes.len) return Error.Truncated;
        defer self.at += 1;
        return self.bytes[self.at];
    }

    pub fn int(self: *Cursor, comptime T: type) Error!T {
        const size = @sizeOf(T);
        const read = try self.take(size);
        return std.mem.readInt(T, read[0..size], .little);
    }

    pub fn take(self: *Cursor, count: usize) Error![]const u8 {
        if (self.bytes.len - self.at < count) return Error.Truncated;
        defer self.at += count;
        return self.bytes[self.at..][0..count];
    }

    pub fn skip(self: *Cursor, count: u64) Error!void {
        _ = try self.take(std.math.cast(usize, count) orelse return Error.Truncated);
    }

    pub fn uleb(self: *Cursor) Error!u64 {
        var result: u64 = 0;
        var shift: u32 = 0;
        while (true) : (shift += 7) {
            if (shift >= 70) return Error.Unsupported;
            const next = try self.byte();
            if (shift < 64) result |= @as(u64, next & 0x7f) << @intCast(shift);
            if (next & 0x80 == 0) return result;
        }
    }

    pub fn sleb(self: *Cursor) Error!i64 {
        var result: u64 = 0;
        var shift: u32 = 0;
        var next: u8 = 0x80;
        while (next & 0x80 != 0) : (shift += 7) {
            if (shift >= 70) return Error.Unsupported;
            next = try self.byte();
            if (shift < 64) result |= @as(u64, next & 0x7f) << @intCast(shift);
        }
        if (shift < 64 and next & 0x40 != 0) result |= ~@as(u64, 0) << @intCast(shift);
        return @bitCast(result);
    }

    /// A NUL-terminated string, returned without its terminator.
    pub fn string(self: *Cursor) Error![]const u8 {
        const end = std.mem.indexOfScalarPos(u8, self.bytes, self.at, 0) orelse return Error.Truncated;
        defer self.at = end + 1;
        return self.bytes[self.at..end];
    }
};

/// The NUL-terminated string at `offset` in a string section.
pub fn stringAt(section: []const u8, offset: u64) Error![]const u8 {
    const start = std.math.cast(usize, offset) orelse return Error.Truncated;
    if (start >= section.len) return Error.Truncated;
    var cursor = Cursor{ .bytes = section, .at = start };
    return cursor.string();
}
