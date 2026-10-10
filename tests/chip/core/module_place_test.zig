//! A parsed module is placed on granule boundaries and copied into its region.
const std = @import("std");
const ra8 = @import("ra8");
const ra8app = ra8.board.image.ra8app;
const place = ra8.chip.core.module_place;

const code_len = 40;
const data_len = 8;
const image_len = ra8app.header_len + code_len + data_len;

fn put(bytes: []u8, index: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[index * 4 ..][0..4], value, .little);
}

fn sample() [image_len]u8 {
    var bytes = @as([image_len]u8, @splat(0));
    const words = [_]u32{ ra8app.magic, ra8app.version, 8, code_len, data_len, 0x400, 1, 0 };
    for (words, 0..) |value, index| put(&bytes, index, value);
    @memcpy(bytes[32..][0..9], "com.hello");
    for (bytes[ra8app.header_len..], 0..) |*byte, index| byte.* = @intCast(index + 1);
    return bytes;
}

const Memory = struct {
    base: u32,
    cells: [256]u8 = @splat(0),
    writes: usize = 0,

    pub fn write(self: *Memory, address: u32, bytes: []const u8) !void {
        const at = address - self.base;
        if (at + bytes.len > self.cells.len) return error.Unmapped;
        @memcpy(self.cells[at..][0..bytes.len], bytes);
        self.writes += 1;
    }
};

test "code starts the region and data starts on the next granule" {
    const bytes = sample();
    const header = try ra8app.parse(&bytes);
    const unit = ra8app.module(header, &bytes);
    const at = try place.plan(unit, .{ .base = 0x2210_0000, .size = 0x100 });
    try std.testing.expectEqual(@as(u32, 0x2210_0000), at.code_base);
    try std.testing.expectEqual(@as(u32, 0x2210_0040), at.data_base);
    try std.testing.expectEqual(@as(u32, 0x2210_0060), at.end);
    try std.testing.expectEqual(@as(u32, 0x2210_0009), at.entry);
}

test "a misaligned base or a region too small is refused before any copy" {
    const bytes = sample();
    const header = try ra8app.parse(&bytes);
    const unit = ra8app.module(header, &bytes);
    try std.testing.expectError(error.Misaligned, place.plan(unit, .{ .base = 0x2210_0010, .size = 0x100 }));
    try std.testing.expectError(error.TooBig, place.plan(unit, .{ .base = 0x2210_0000, .size = 0x5F }));
    _ = try place.plan(unit, .{ .base = 0x2210_0000, .size = 0x60 });
}

test "a region at the top of the address space does not wrap" {
    const bytes = sample();
    const header = try ra8app.parse(&bytes);
    const unit = ra8app.module(header, &bytes);
    try std.testing.expectError(error.TooBig, place.plan(unit, .{ .base = 0xFFFF_FFE0, .size = 0xFFFF_FFFF }));
}

test "load copies code and data to their planned addresses" {
    const bytes = sample();
    const header = try ra8app.parse(&bytes);
    const unit = ra8app.module(header, &bytes);
    var memory: Memory = .{ .base = 0x2210_0000 };
    const at = try place.plan(unit, .{ .base = memory.base, .size = 0x100 });
    try place.load(&memory, unit, at);
    try std.testing.expectEqual(@as(usize, 2), memory.writes);
    try std.testing.expectEqualSlices(u8, ra8app.code(header, &bytes), memory.cells[0..code_len]);
    try std.testing.expectEqualSlices(u8, ra8app.data(header, &bytes), memory.cells[0x40..][0..data_len]);
    try std.testing.expectEqual(@as(u8, 0), memory.cells[code_len]);
}
