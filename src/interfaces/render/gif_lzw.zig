//! GIF LZW over 8-bit palette indices: codes widen from 9 to 12 bits and the
//! table clears when it reaches 4096 entries, as the GIF89a spec describes.
const std = @import("std");

pub const min_code_size: u8 = 8;
pub const clear: u16 = 256;
pub const end: u16 = 257;
const first_free: u16 = 258;
const max_codes: u16 = 4096;
const max_width: u4 = 12;

/// Packs codes least significant bit first, as GIF requires.
const BitSink = struct {
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    bits: u32 = 0,
    count: u5 = 0,

    fn put(self: *BitSink, code: u16, width: u4) !void {
        self.bits |= @as(u32, code) << self.count;
        self.count += width;
        while (self.count >= 8) {
            try self.out.append(self.gpa, @truncate(self.bits));
            self.bits >>= 8;
            self.count -= 8;
        }
    }

    fn flush(self: *BitSink) !void {
        if (self.count != 0) try self.out.append(self.gpa, @truncate(self.bits));
        self.bits = 0;
        self.count = 0;
    }
};

/// The width the decoder will read the next code at, once it has caught up
/// with `next` table entries.
fn widen(width: u4, next: u16) u4 {
    return if (width < max_width and next == (@as(u16, 1) << width)) width + 1 else width;
}

/// Appends the LZW code stream for `indices` (clear first, end last) to `out`.
pub fn encode(allocator: std.mem.Allocator, indices: []const u8, out: *std.ArrayList(u8)) !void {
    var table = std.AutoHashMap(u32, u16).init(allocator);
    defer table.deinit();
    try table.ensureTotalCapacity(max_codes);
    var sink: BitSink = .{ .gpa = allocator, .out = out };
    var width: u4 = 9;
    var next: u16 = first_free;
    try sink.put(clear, width);
    if (indices.len == 0) {
        try sink.put(end, width);
        return sink.flush();
    }
    var prefix: u16 = indices[0];
    for (indices[1..]) |byte| {
        const key = (@as(u32, prefix) << 8) | byte;
        if (table.get(key)) |code| {
            prefix = code;
            continue;
        }
        try sink.put(prefix, width);
        if (next == max_codes) {
            try sink.put(clear, width);
            table.clearRetainingCapacity();
            next = first_free;
            width = 9;
        } else {
            width = widen(width, next);
            table.putAssumeCapacityNoClobber(key, next);
            next += 1;
        }
        prefix = byte;
    }
    try sink.put(prefix, width);
    if (next < max_codes) width = widen(width, next);
    try sink.put(end, width);
    try sink.flush();
}
