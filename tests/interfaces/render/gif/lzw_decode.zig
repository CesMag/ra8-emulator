//! Test-side GIF LZW decoder (9 to 12 bit codes, clear and end), used to
//! round-trip what gif.lzw.encode writes.
const std = @import("std");

const Entry = struct { prefix: u16, suffix: u8, first: u8, len: u32 };

fn readCode(bytes: []const u8, bit: usize, width: u4) u16 {
    var code: u16 = 0;
    for (0..width) |shift| {
        const at = bit + shift;
        code |= @as(u16, (bytes[at / 8] >> @intCast(at % 8)) & 1) << @intCast(shift);
    }
    return code;
}

fn emit(allocator: std.mem.Allocator, out: *std.ArrayList(u8), table: *const [4096]Entry, code: u16) !void {
    const start = out.items.len;
    try out.resize(allocator, start + table[code].len);
    var at = code;
    var index: usize = table[code].len;
    while (index > 0) {
        index -= 1;
        out.items[start + index] = table[at].suffix;
        at = table[at].prefix;
    }
}

/// Decodes one LZW stream (as written after the minimum code size byte).
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var table: [4096]Entry = undefined;
    for (0..256) |i| table[i] = .{ .prefix = 0, .suffix = @intCast(i), .first = @intCast(i), .len = 1 };
    var width: u4 = 9;
    var next: u16 = 258;
    var prev: ?u16 = null;
    var bit: usize = 0;
    while (bit + width <= bytes.len * 8) {
        const code = readCode(bytes, bit, width);
        bit += width;
        if (code == 256) {
            width = 9;
            next = 258;
            prev = null;
            continue;
        }
        if (code == 257) return out.toOwnedSlice(allocator);
        if (prev) |p| {
            if (code > next) return error.BadCode;
            const first = if (code < next) table[code].first else table[p].first;
            if (next < 4096) {
                table[next] = .{ .prefix = p, .suffix = first, .first = table[p].first, .len = table[p].len + 1 };
                next += 1;
            }
            if (width < 12 and next == (@as(u16, 1) << width)) width += 1;
        } else if (code >= 256) return error.BadCode;
        try emit(allocator, &out, &table, code);
        prev = code;
    }
    return error.NoEnd;
}
