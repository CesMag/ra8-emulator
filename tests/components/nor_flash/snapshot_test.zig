//! Covers src/components/nor_flash/snapshot.zig (RA8EMU-1104): the NOR
//! flash's half of the `storage` section reads back into a fresh part with
//! its written sectors, a file saved for another capacity does not fit, and
//! a sector past the part is refused.
const std = @import("std");
const ra8 = @import("ra8");
const half = ra8.components.nor_flash.snapshot;
const fields = ra8.snapshot.fields;
const Flash = ra8.components.nor_flash.Flash;
const allocator = std.testing.allocator;

fn busy() !Flash {
    var part = Flash.init(allocator);
    errdefer part.deinit();
    try part.program(0x2000, 0x0F);
    try part.program(0x10_0004, 0xA5);
    return part;
}

fn written(part: *const Flash, out: *std.Io.Writer.Allocating) !void {
    try half.write(&out.writer, part);
}

test "the part reads back into a fresh one with its sectors" {
    var part = try busy();
    defer part.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try written(&part, &out);
    // Capacity, the sector count, then two sectors of a number and 4 KiB.
    try std.testing.expectEqual(@as(usize, 4 + 4 + 2 * (4 + 0x1000)), out.written().len);
    try std.testing.expectEqual(part.capacity, std.mem.readInt(u32, out.written()[0..4], .little));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, out.written()[4..8], .little));

    var fresh = Flash.init(allocator);
    defer fresh.deinit();
    try fresh.program(0x9000, 0x11);
    var cursor: fields.Cursor = .{ .bytes = out.written() };
    const staged = try half.read(&cursor);
    try std.testing.expect(cursor.done());
    try std.testing.expect(staged.fits(&fresh));
    try std.testing.expectEqual(@as(u32, 1), fresh.live());

    half.install(&fresh, try staged.build(&fresh));
    try std.testing.expectEqual(@as(u32, 2), fresh.live());
    try std.testing.expectEqual(@as(u8, 0x0F), fresh.byte(0x2000));
    try std.testing.expectEqual(@as(u8, 0xA5), fresh.byte(0x10_0004));
    try std.testing.expectEqual(Flash.init(allocator).byte(0x9000), fresh.byte(0x9000));
    var again = std.Io.Writer.Allocating.init(allocator);
    defer again.deinit();
    try written(&fresh, &again);
    try std.testing.expectEqualSlices(u8, out.written(), again.written());
}

test "a file saved for another capacity does not fit" {
    var part = try busy();
    defer part.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try written(&part, &out);
    var smaller = Flash.init(allocator);
    defer smaller.deinit();
    try smaller.resize(32 * 1024 * 1024);
    var cursor: fields.Cursor = .{ .bytes = out.written() };
    const staged = try half.read(&cursor);
    try std.testing.expect(!staged.fits(&smaller));
    try std.testing.expect(staged.fits(&part));
}

test "a sector past this part does not fit, and one past any part is refused" {
    var part = try busy();
    defer part.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try written(&part, &out);
    const bytes = out.written();
    // The last sector entry's number sits 4 KiB + 4 bytes from the end.
    const at = bytes.len - 4 - 0x1000;
    std.mem.writeInt(u32, bytes[at..][0..4], 0xFFFF, .little);
    var cursor: fields.Cursor = .{ .bytes = bytes };
    const staged = try half.read(&cursor);
    try std.testing.expect(!staged.fits(&part));
    std.mem.writeInt(u32, bytes[at..][0..4], 0x1_0000, .little);
    cursor = .{ .bytes = bytes };
    try std.testing.expectError(error.BadValue, half.read(&cursor));
}
