//! Covers src/chip/periph/mram/snapshot.zig (RA8EMU-1104): the option
//! MRAM's half of the `storage` section reads back into a fresh unit with
//! its OTP cells, nothing changes before `install`, a cell outside the OTP
//! window is refused, and a command stream longer than its buffer does not
//! fit.
const std = @import("std");
const ra8 = @import("ra8");
const half = ra8.chip.periph.mram.snapshot;
const fields = ra8.snapshot.fields;
const Mram = ra8.chip.periph.mram.Mram;
const allocator = std.testing.allocator;

const cell = 0x02E0_7610;

fn busy() !Mram {
    var unit = Mram.init(allocator);
    errdefer unit.deinit();
    try unit.otp.program(cell, &.{ 0x12, 0x34, 0x56, 0x78 });
    unit.shadow[2] = 0xCAFE;
    unit.stream.len = 4;
    unit.locked = true;
    unit.programs = 3;
    return unit;
}

test "the unit reads back into a fresh one with its cells" {
    var unit = try busy();
    defer unit.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try half.write(&out.writer, &unit);

    var fresh = Mram.init(allocator);
    defer fresh.deinit();
    try fresh.otp.program(cell + 0x100, &.{0xEE});
    var cursor: fields.Cursor = .{ .bytes = out.written() };
    var staged = try half.read(&cursor, &fresh);
    try std.testing.expect(cursor.done());
    try std.testing.expect(staged.fits());
    try std.testing.expect(!fresh.locked);
    try std.testing.expectEqual(@as(u32, 1), fresh.otp.live());

    staged.install(&fresh, try staged.build());
    try std.testing.expect(fresh.locked);
    try std.testing.expectEqual(@as(u32, 0xCAFE), fresh.shadow[2]);
    try std.testing.expectEqual(@as(u32, 3), fresh.programs);
    try std.testing.expectEqual(@as(u32, 4), fresh.otp.live());
    try std.testing.expectEqual(@as(u8, 0x34), fresh.otp.byte(cell + 1));
    var again = std.Io.Writer.Allocating.init(allocator);
    defer again.deinit();
    try half.write(&again.writer, &fresh);
    try std.testing.expectEqualSlices(u8, out.written(), again.written());
}

test "a cell outside the OTP window is refused" {
    var unit = try busy();
    defer unit.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try half.write(&out.writer, &unit);
    const bytes = out.written();
    // The first cell's entry: its address, then its byte.
    const first = std.mem.indexOf(u8, bytes, &[_]u8{ 0x10, 0x76, 0xE0, 0x02, 0x12 }).?;
    std.mem.writeInt(u32, bytes[first..][0..4], 0x0200_0000, .little);
    var fresh = Mram.init(allocator);
    defer fresh.deinit();
    var cursor: fields.Cursor = .{ .bytes = bytes };
    try std.testing.expectError(error.BadValue, half.read(&cursor, &fresh));
    try std.testing.expectEqual(@as(u32, 0), fresh.otp.live());
}

test "a command stream longer than its buffer does not fit" {
    var unit = try busy();
    defer unit.deinit();
    unit.stream.len = unit.stream.payload.len + 1;
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try half.write(&out.writer, &unit);
    var fresh = Mram.init(allocator);
    defer fresh.deinit();
    var cursor: fields.Cursor = .{ .bytes = out.written() };
    const staged = try half.read(&cursor, &fresh);
    try std.testing.expect(!staged.fits());
}
