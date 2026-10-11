//! The mass-storage target: a CBW in, the data stage and a CSW back out.
const std = @import("std");
const ra8 = @import("ra8");
const msc = ra8.components.usb.stick;

fn cbw(tag: u32, length: u32, cdb: []const u8) [msc.cbw_len]u8 {
    var packet = @as([msc.cbw_len]u8, @splat(0));
    std.mem.writeInt(u32, packet[0..4], msc.cbw_signature, .little);
    std.mem.writeInt(u32, packet[4..8], tag, .little);
    std.mem.writeInt(u32, packet[8..12], length, .little);
    packet[12] = 0x80;
    packet[14] = @intCast(cdb.len);
    @memcpy(packet[15 .. 15 + cdb.len], cdb);
    return packet;
}

fn csw(target: *msc.Target) [msc.csw_len]u8 {
    var out = @as([msc.csw_len]u8, @splat(0));
    std.testing.expectEqual(msc.csw_len, target.reply(&out)) catch unreachable;
    return out;
}

var disk_bytes = blk: {
    @setEvalBranchQuota(8 * msc.block_len);
    var bytes = @as([4 * msc.block_len]u8, @splat(0));
    for (&bytes, 0..) |*b, i| b.* = @truncate(i / msc.block_len + 0xA0);
    break :blk bytes;
};

test "INQUIRY answers a direct-access device, then a passing CSW with the tag" {
    var target = msc.Target{ .disk = &disk_bytes };
    try std.testing.expect(target.command(&cbw(7, 36, &.{ msc.op.inquiry, 0, 0, 0, 36, 0 })));
    var buf: [512]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 36), target.reply(&buf));
    try std.testing.expectEqual(@as(u8, 0x00), buf[0]);
    try std.testing.expectEqualStrings("RA8EMU  ", buf[8..16]);
    const status = csw(&target);
    try std.testing.expectEqual(msc.csw_signature, std.mem.readInt(u32, status[0..4], .little));
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, status[4..8], .little));
    try std.testing.expectEqual(@as(u8, 0), status[12]);
}

test "a host that asks for more than INQUIRY has gets the residue in the CSW" {
    var target = msc.Target{ .disk = &disk_bytes };
    _ = target.command(&cbw(1, 64, &.{ msc.op.inquiry, 0, 0, 0, 64, 0 }));
    var buf: [512]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 36), target.reply(&buf));
    const status = csw(&target);
    try std.testing.expectEqual(@as(u32, 28), std.mem.readInt(u32, status[8..12], .little));
}

test "READ CAPACITY reports the last block and the block length" {
    var target = msc.Target{ .disk = &disk_bytes };
    _ = target.command(&cbw(2, 8, &.{ msc.op.read_capacity10, 0, 0, 0, 0, 0, 0, 0, 0, 0 }));
    var buf: [512]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 8), target.reply(&buf));
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, buf[0..4], .big));
    try std.testing.expectEqual(msc.block_len, std.mem.readInt(u32, buf[4..8], .big));
}

test "READ(10) hands back the sector asked for, one packet at a time" {
    var target = msc.Target{ .disk = &disk_bytes };
    _ = target.command(&cbw(3, 1024, &.{ msc.op.read10, 0, 0, 0, 0, 2, 0, 0, 2, 0 }));
    var buf: [512]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 512), target.reply(&buf));
    try std.testing.expectEqual(@as(u8, 0xA2), buf[0]);
    try std.testing.expectEqual(@as(usize, 512), target.reply(&buf));
    try std.testing.expectEqual(@as(u8, 0xA3), buf[511]);
    const status = csw(&target);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, status[8..12], .little));
    try std.testing.expectEqual(@as(u8, 0), status[12]);
    try std.testing.expectEqual(@as(u32, 1), target.reads);
}

test "a read past the end fails and REQUEST SENSE says why, once" {
    var target = msc.Target{ .disk = &disk_bytes };
    _ = target.command(&cbw(4, 512, &.{ msc.op.read10, 0, 0, 0, 0, 4, 0, 0, 1, 0 }));
    try std.testing.expectEqual(@as(u8, 1), csw(&target)[12]);
    _ = target.command(&cbw(5, 18, &.{ msc.op.request_sense, 0, 0, 0, 18, 0 }));
    var buf: [512]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 18), target.reply(&buf));
    try std.testing.expectEqual(@as(u8, 0x05), buf[2]);
    try std.testing.expectEqual(@as(u8, 0x21), buf[12]);
    _ = csw(&target);
    _ = target.command(&cbw(6, 18, &.{ msc.op.request_sense, 0, 0, 0, 18, 0 }));
    _ = target.reply(&buf);
    try std.testing.expectEqual(@as(u8, 0), buf[2]);
}

test "a command it doesn't implement fails in the CSW, not on the pipe" {
    var target = msc.Target{ .disk = &disk_bytes };
    try std.testing.expect(target.command(&cbw(8, 0, &.{ 0x04, 0, 0, 0, 0, 0 })));
    try std.testing.expectEqual(@as(u8, 1), csw(&target)[12]);
    try std.testing.expectEqual(msc.Sense.invalid_opcode, target.sense);
}

test "no disk means TEST UNIT READY reports no medium" {
    var target = msc.Target{};
    _ = target.command(&cbw(9, 0, &.{ msc.op.test_unit_ready, 0, 0, 0, 0, 0 }));
    try std.testing.expectEqual(@as(u8, 1), csw(&target)[12]);
    try std.testing.expectEqual(msc.Sense.no_medium, target.sense);
}

test "a packet that isn't a CBW is refused, and so is a second command before the CSW" {
    var target = msc.Target{ .disk = &disk_bytes };
    var bad = cbw(1, 0, &.{msc.op.test_unit_ready});
    bad[0] = 0;
    try std.testing.expect(!target.command(&bad));
    try std.testing.expect(!target.command(bad[0..12]));
    try std.testing.expect(target.command(&cbw(2, 0, &.{msc.op.test_unit_ready})));
    try std.testing.expect(!target.command(&cbw(3, 0, &.{msc.op.test_unit_ready})));
    try std.testing.expectEqual(@as(u32, 3), target.invalid);
}

test "a bus reset drops the command in flight" {
    var target = msc.Target{ .disk = &disk_bytes };
    _ = target.command(&cbw(1, 512, &.{ msc.op.read10, 0, 0, 0, 0, 0, 0, 0, 1, 0 }));
    target.reset();
    var buf: [512]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), target.reply(&buf));
    try std.testing.expect(target.command(&cbw(2, 0, &.{msc.op.test_unit_ready})));
}

test "WRITE(10) takes its data on bulk OUT, then reads back what it wrote" {
    var target = msc.Target{ .disk = &disk_bytes };
    const saved = disk_bytes[2 * msc.block_len ..][0..msc.block_len].*;
    defer disk_bytes[2 * msc.block_len ..][0..msc.block_len].* = saved;
    try std.testing.expect(target.command(&cbw(5, 512, &.{ msc.op.write10, 0, 0, 0, 0, 2, 0, 0, 1, 0 })));
    try std.testing.expectEqual(msc.Phase.data_out, target.phase);
    var buf: [512]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), target.reply(&buf));
    const half = @as([256]u8, @splat(0x11));
    try std.testing.expect(target.command(&half));
    try std.testing.expectEqual(msc.Phase.data_out, target.phase);
    try std.testing.expect(target.command(&(@as([256]u8, @splat(0x22)))));
    const status = csw(&target);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, status[8..12], .little));
    try std.testing.expectEqual(@as(u8, 0), status[12]);
    try std.testing.expectEqual(@as(u32, 1), target.writes);
    try std.testing.expect(target.command(&cbw(6, 512, &.{ msc.op.read10, 0, 0, 0, 0, 2, 0, 0, 1, 0 })));
    try std.testing.expectEqual(@as(usize, 512), target.reply(&buf));
    try std.testing.expectEqual(@as(u8, 0x11), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x22), buf[511]);
}

test "WRITE(10) past the end fails without a data stage" {
    var target = msc.Target{ .disk = &disk_bytes };
    try std.testing.expect(target.command(&cbw(8, 512, &.{ msc.op.write10, 0, 0, 0, 0, 4, 0, 0, 1, 0 })));
    try std.testing.expectEqual(msc.Phase.status, target.phase);
    try std.testing.expectEqual(@as(u8, 1), csw(&target)[12]);
}

test "SYNCHRONIZE CACHE passes on a disk with medium" {
    var target = msc.Target{ .disk = &disk_bytes };
    try std.testing.expect(target.command(&cbw(9, 0, &.{ msc.op.synchronize_cache10, 0, 0, 0, 0, 0, 0, 0, 0, 0 })));
    try std.testing.expectEqual(@as(u8, 0), csw(&target)[12]);
}

test "a bus reset in the middle of a write drops the rest of it" {
    var target = msc.Target{ .disk = &disk_bytes };
    _ = target.command(&cbw(3, 512, &.{ msc.op.write10, 0, 0, 0, 0, 3, 0, 0, 1, 0 }));
    target.reset();
    try std.testing.expectEqual(msc.Phase.command, target.phase);
    try std.testing.expect(!target.command(&(@as([8]u8, @splat(0)))));
}
