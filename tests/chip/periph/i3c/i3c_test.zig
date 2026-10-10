//! The I3C channel in legacy I2C mode: the transfer machine and what it
//! refuses.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.periph.riic_bus;
const flag = ra8.chip.periph.i3c_flags;
const gt911 = ra8.components.gt911;
const i3c = ra8.chip.periph.i3c;
const reset = ra8.chip.periph.i3c_reset;

/// A part that answers with a fixed reply and remembers what it was told.
const Echo = struct {
    reply: []const u8 = &[_]u8{},
    heard: [8]u8 = @splat(0),
    heard_len: usize = 0,
    stops: u32 = 0,

    fn write(context: *anyopaque, byte: u8) void {
        const self: *Echo = @ptrCast(@alignCast(context));
        if (self.heard_len < self.heard.len) {
            self.heard[self.heard_len] = byte;
            self.heard_len += 1;
        }
    }

    fn read(context: *anyopaque, into: []u8) usize {
        const self: *Echo = @ptrCast(@alignCast(context));
        const served = @min(into.len, self.reply.len);
        for (into[0..served], self.reply[0..served]) |*slot, byte| slot.* = byte;
        return served;
    }

    fn ended(context: *anyopaque) void {
        const self: *Echo = @ptrCast(@alignCast(context));
        self.stops += 1;
    }

    fn device(self: *Echo, at: u7) bus.Device {
        return .{
            .address = at,
            .context = self,
            .writeFn = write,
            .readFn = read,
            .stopFn = ended,
        };
    }
};

fn start(unit: *i3c.I3c) void {
    unit.writeOffset(flag.reg.cndctl, flag.cndctl.stcnd);
}

fn repeat(unit: *i3c.I3c) void {
    unit.writeOffset(flag.reg.cndctl, flag.cndctl.srcnd);
}

fn stop(unit: *i3c.I3c) void {
    unit.writeOffset(flag.reg.cndctl, flag.cndctl.spcnd);
}

fn address(unit: *i3c.I3c, target: u7, reading: bool) void {
    unit.writeOffset(flag.reg.ntdtbp0, bus.wire.byte(target, reading));
}

/// The first buffer read of a receive is the dummy one that starts the clock.
fn drain(unit: *i3c.I3c, into: []u8) void {
    _ = unit.readOffset(flag.reg.ntdtbp0);
    for (into) |*slot| slot.* = @truncate(unit.readOffset(flag.reg.ntdtbp0));
}

test "the bus reads free until a transaction opens" {
    var unit = i3c.I3c{};
    try std.testing.expectEqual(flag.bcst.bfref, unit.readOffset(flag.reg.bcst));
    start(&unit);
    try std.testing.expectEqual(@as(u32, 0), unit.readOffset(flag.reg.bcst));
    stop(&unit);
    try std.testing.expectEqual(flag.bcst.bfref, unit.readOffset(flag.reg.bcst));
}

test "a start raises the condition-detect flag dev declared and never set" {
    var unit = i3c.I3c{};
    start(&unit);
    try std.testing.expect(unit.readOffset(flag.reg.bst) & flag.bst.stcnddf != 0);
    stop(&unit);
    try std.testing.expect(unit.readOffset(flag.reg.bst) & flag.bst.spcnddf != 0);
}

test "the condition request clears itself once the condition is issued" {
    var unit = i3c.I3c{};
    start(&unit);
    try std.testing.expectEqual(@as(u32, 0), unit.readOffset(flag.reg.cndctl));
}

test "bus status flags are write-0-to-clear" {
    var unit = i3c.I3c{};
    start(&unit);
    const held = unit.readOffset(flag.reg.bst);
    unit.writeOffset(flag.reg.bst, held & ~flag.bst.stcnddf);
    try std.testing.expect(unit.readOffset(flag.reg.bst) & flag.bst.stcnddf == 0);
}

test "an unmodelled register reflects what was written to it" {
    var unit = i3c.I3c{};
    unit.writeOffset(0x0C, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), unit.readOffset(0x0C));
}

test "an access past the window answers nothing and changes nothing" {
    var unit = i3c.I3c{};
    unit.writeOffset(flag.win_span, 0x1234);
    try std.testing.expectEqual(@as(u32, 0), unit.readOffset(flag.win_span));
}

test "a write transfer reaches the part and ends at stop" {
    var unit = i3c.I3c{};
    var part = Echo{};
    try unit.attachDevice(part.device(0x43));
    start(&unit);
    address(&unit, 0x43, false);
    unit.writeOffset(flag.reg.ntdtbp0, 0x11);
    unit.writeOffset(flag.reg.ntdtbp0, 0x22);
    stop(&unit);
    try std.testing.expectEqual(@as(usize, 2), part.heard_len);
    try std.testing.expectEqual(@as(u8, 0x22), part.heard[1]);
    try std.testing.expectEqual(@as(u32, 1), part.stops);
    try std.testing.expectEqual(@as(u32, 1), unit.transfers);
    try std.testing.expectEqual(@as(u32, 2), unit.sent);
}

test "an addressed part raises the transfer-end flag a scan waits on" {
    var unit = i3c.I3c{};
    var part = Echo{};
    try unit.attachDevice(part.device(0x43));
    start(&unit);
    address(&unit, 0x43, false);
    try std.testing.expect(unit.readOffset(flag.reg.bst) & flag.bst.tendf != 0);
    try std.testing.expect(unit.readOffset(flag.reg.bst) & flag.bst.nackdf == 0);
}

test "an address nothing answers is NACKed and counted as a scan miss" {
    var unit = i3c.I3c{};
    start(&unit);
    address(&unit, 0x21, false);
    try std.testing.expect(unit.readOffset(flag.reg.bst) & flag.bst.nackdf != 0);
    try std.testing.expectEqual(@as(u32, 1), unit.nacks);
    stop(&unit);
    try std.testing.expectEqual(@as(u32, 0), unit.transfers);
}

test "an address I2C keeps for itself is refused apart from a scan miss" {
    var unit = i3c.I3c{};
    start(&unit);
    address(&unit, 0x7B, false);
    try std.testing.expectEqual(@as(u32, 1), unit.reserved);
    try std.testing.expectEqual(@as(u32, 0), unit.nacks);
}

test "payload after a NACKed address goes nowhere" {
    var unit = i3c.I3c{};
    var part = Echo{};
    try unit.attachDevice(part.device(0x43));
    start(&unit);
    address(&unit, 0x21, false);
    unit.writeOffset(flag.reg.ntdtbp0, 0xFF);
    try std.testing.expectEqual(@as(usize, 0), part.heard_len);
}

test "a read serves the staged reply after the dummy first read" {
    var unit = i3c.I3c{};
    var part = Echo{ .reply = &[_]u8{ 0xDE, 0xAD } };
    try unit.attachDevice(part.device(0x43));
    start(&unit);
    address(&unit, 0x43, true);
    try std.testing.expect(unit.readOffset(flag.reg.ntst) & flag.ntst.rdbff0 != 0);
    var buffer: [2]u8 = undefined;
    drain(&unit, buffer[0..]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xDE, 0xAD }, buffer[0..]);
    try std.testing.expectEqual(@as(u32, 2), unit.received);
}

test "the buffer stops reading full with the last byte" {
    var unit = i3c.I3c{};
    var part = Echo{ .reply = &[_]u8{0x5A} };
    try unit.attachDevice(part.device(0x43));
    start(&unit);
    address(&unit, 0x43, true);
    var buffer: [1]u8 = undefined;
    drain(&unit, buffer[0..]);
    try std.testing.expect(unit.readOffset(flag.reg.ntst) & flag.ntst.rdbff0 == 0);
}

test "a read past what the part had to say is refused, not served as zeros" {
    var unit = i3c.I3c{};
    var part = Echo{ .reply = &[_]u8{0x5A} };
    try unit.attachDevice(part.device(0x43));
    start(&unit);
    address(&unit, 0x43, true);
    var buffer: [1]u8 = undefined;
    drain(&unit, buffer[0..]);
    // dev kept the buffer flagged full here and served zeros forever.
    try std.testing.expectEqual(@as(u32, 0), unit.readOffset(flag.reg.ntdtbp0));
    try std.testing.expectEqual(@as(u32, 1), unit.overdrain);
    try std.testing.expectEqual(@as(u32, 1), unit.received);
}

test "a byte written with no transaction open is refused" {
    var unit = i3c.I3c{};
    var part = Echo{};
    try unit.attachDevice(part.device(0x43));
    // dev took this as an address byte and selected the part.
    address(&unit, 0x43, false);
    try std.testing.expectEqual(@as(u32, 1), unit.no_start);
    try std.testing.expect(!unit.addressed);
    try std.testing.expectEqual(@as(usize, 0), part.heard_len);
}

test "a start on a busy bus is refused and the open transfer survives" {
    var unit = i3c.I3c{};
    var part = Echo{};
    try unit.attachDevice(part.device(0x43));
    start(&unit);
    address(&unit, 0x43, false);
    start(&unit);
    try std.testing.expectEqual(@as(u32, 1), unit.st_busy);
    try std.testing.expect(unit.addressed);
    try std.testing.expectEqual(@as(u7, 0x43), unit.target_7b);
}

test "a repeated start on an idle bus has nothing to repeat" {
    var unit = i3c.I3c{};
    repeat(&unit);
    try std.testing.expectEqual(@as(u32, 1), unit.rs_idle);
    try std.testing.expect(!unit.busy);
}

test "a repeated start turns a write transfer around into a read" {
    var unit = i3c.I3c{};
    var panel = gt911.Panel{};
    try unit.attachDevice(panel.device());
    start(&unit);
    address(&unit, gt911.address, false);
    unit.writeOffset(flag.reg.ntdtbp0, 0x81);
    unit.writeOffset(flag.reg.ntdtbp0, 0x40);
    repeat(&unit);
    address(&unit, gt911.address, true);
    var buffer: [4]u8 = undefined;
    drain(&unit, buffer[0..]);
    try std.testing.expectEqualSlices(u8, &gt911.product_id, buffer[0..]);
    stop(&unit);
    try std.testing.expectEqual(@as(u32, 1), unit.transfers);
}

test "the touch panel answers a whole frame through the controller" {
    var unit = i3c.I3c{};
    var panel = gt911.Panel{};
    panel.press(.{ .x = 0x0140, .y = 0x00C8 });
    try unit.attachDevice(panel.device());
    start(&unit);
    address(&unit, gt911.address, false);
    unit.writeOffset(flag.reg.ntdtbp0, 0x81);
    unit.writeOffset(flag.reg.ntdtbp0, 0x4E);
    repeat(&unit);
    address(&unit, gt911.address, true);
    var status: [1]u8 = undefined;
    drain(&unit, status[0..]);
    try std.testing.expectEqual(gt911.status.ready | gt911.status.one_point, status[0]);
    stop(&unit);
    start(&unit);
    address(&unit, gt911.address, false);
    unit.writeOffset(flag.reg.ntdtbp0, 0x81);
    unit.writeOffset(flag.reg.ntdtbp0, 0x4F);
    repeat(&unit);
    address(&unit, gt911.address, true);
    var record: [gt911.record.bytes]u8 = undefined;
    drain(&unit, record[0..]);
    stop(&unit);
    try std.testing.expectEqual(@as(u8, 0x40), record[gt911.record.x_lsb]);
    try std.testing.expectEqual(@as(u8, 0x01), record[gt911.record.x_msb]);
    try std.testing.expectEqual(@as(u32, 1), panel.reported);
}

test "claiming an own address hands the buffer to the responder" {
    var unit = i3c.I3c{};
    unit.writeOffset(flag.reg.msdvad, @as(u32, 0x22) << 1);
    try std.testing.expect(unit.responder.armed);
    try std.testing.expectEqual(flag.ntst.rdbff0, unit.readOffset(flag.reg.ntst));
    const byte = unit.readOffset(flag.reg.ntdtbp0);
    unit.writeOffset(flag.reg.ntdtbp0, byte);
    try std.testing.expectEqual(@as(u32, 1), unit.responder.cycles);
}

test "an own address claimed mid-transfer is refused" {
    var unit = i3c.I3c{};
    var part = Echo{};
    try unit.attachDevice(part.device(0x43));
    start(&unit);
    address(&unit, 0x43, false);
    unit.writeOffset(flag.reg.msdvad, @as(u32, 0x22) << 1);
    try std.testing.expect(!unit.responder.armed);
    try std.testing.expectEqual(@as(u32, 1), unit.role_clash);
    unit.writeOffset(flag.reg.ntdtbp0, 0x11);
    try std.testing.expectEqual(@as(usize, 1), part.heard_len);
}

test "a start while the responder is armed is refused" {
    var unit = i3c.I3c{};
    unit.writeOffset(flag.reg.msdvad, @as(u32, 0x22) << 1);
    start(&unit);
    try std.testing.expect(!unit.busy);
    try std.testing.expectEqual(@as(u32, 1), unit.role_clash);
}

test "giving the own address back up returns the buffer to the controller" {
    var unit = i3c.I3c{};
    var part = Echo{};
    try unit.attachDevice(part.device(0x43));
    unit.writeOffset(flag.reg.msdvad, @as(u32, 0x22) << 1);
    unit.writeOffset(flag.reg.msdvad, 0);
    start(&unit);
    address(&unit, 0x43, false);
    unit.writeOffset(flag.reg.ntdtbp0, 0x77);
    try std.testing.expectEqual(@as(u8, 0x77), part.heard[0]);
}

test "the block answers on its own window" {
    var unit = i3c.I3c{};
    const block = unit.block();
    try std.testing.expectEqual(flag.win_base, block.base);
    try std.testing.expectEqual(flag.win_span, block.size);
    unit.write(flag.win_base + flag.reg.cndctl, 4, flag.cndctl.stcnd);
    try std.testing.expectEqual(@as(u32, 0), unit.read(flag.win_base + flag.reg.bcst, 4));
}

test "a channel nothing drove is quiet" {
    var unit = i3c.I3c{};
    try std.testing.expect(unit.quiet());
    start(&unit);
    stop(&unit);
    try std.testing.expect(unit.quiet());
    address(&unit, 0x43, false);
    try std.testing.expect(!unit.quiet());
}

test "RSTCTL reads back clear so the driver's self-clear poll finishes" {
    var unit = i3c.I3c{};
    // internal_i3c_i2c_reset writes the bit, writes zero, then spins.
    unit.writeOffset(reset.off, reset.mask.ri3crst);
    try std.testing.expectEqual(@as(u32, 0), unit.readOffset(reset.off));
    // A narrow store that names the lane carries the command just as well.
    unit.write(flag.win_base + reset.off, 1, reset.mask.ri3crst);
    try std.testing.expectEqual(@as(u32, 2), unit.resetCount());
}

test "a reset takes a channel left mid-transfer back to idle" {
    var unit = i3c.I3c{};
    var part = Echo{};
    try unit.attachDevice(part.device(0x43));
    // Bring-up resets FIRST, so configuration has to ride through a reset.
    unit.writeOffset(0x0B4, 0xDEAD_BEEF);
    // Leave a transaction open, the way an aborted transfer does.
    unit.writeOffset(flag.reg.cndctl, flag.cndctl.stcnd);
    unit.writeOffset(flag.reg.ntdtbp0, 0x43 << 1);
    try std.testing.expectEqual(@as(u32, 0), unit.readOffset(flag.reg.bcst) & flag.bcst.bfref);

    unit.writeOffset(reset.off, reset.mask.ri3crst);
    try std.testing.expectEqual(flag.bcst.bfref, unit.readOffset(flag.reg.bcst) & flag.bcst.bfref);
    try std.testing.expectEqual(@as(u32, 0), unit.readOffset(flag.reg.bst));
    try std.testing.expectEqual(flag.ntst.tdbef0, unit.readOffset(flag.reg.ntst));
    try std.testing.expectEqual(@as(u32, 1), unit.reset_busy);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), unit.readOffset(0x0B4));

    // INTLRST takes it down the same way, from a fresh transaction.
    unit.writeOffset(flag.reg.cndctl, flag.cndctl.stcnd);
    unit.writeOffset(reset.off, reset.mask.intlrst);
    try std.testing.expectEqual(flag.bcst.bfref, unit.readOffset(flag.reg.bcst) & flag.bcst.bfref);
}

test "a reset leaves nothing staged for the next read to serve" {
    var unit = i3c.I3c{};
    var part = Echo{ .reply = &[_]u8{ 0xDE, 0xAD } };
    try unit.attachDevice(part.device(0x43));
    unit.writeOffset(flag.reg.cndctl, flag.cndctl.stcnd);
    unit.writeOffset(flag.reg.ntdtbp0, (0x43 << 1) | 1);
    _ = unit.readOffset(flag.reg.ntdtbp0);

    unit.writeOffset(reset.off, reset.mask.ri3crst);
    // No transaction open, so the next buffer write has no START.
    unit.writeOffset(flag.reg.ntdtbp0, 0x00);
    try std.testing.expectEqual(@as(u32, 1), unit.no_start);
}

test "a per-queue reset is spent and counted but moves no transfer" {
    var unit = i3c.I3c{};
    unit.writeOffset(flag.reg.cndctl, flag.cndctl.stcnd);
    unit.writeOffset(reset.off, reset.mask.tdbrst);
    try std.testing.expectEqual(@as(u32, 0), unit.readOffset(reset.off));
    try std.testing.expectEqual(@as(u32, 1), unit.resetCount());
    try std.testing.expectEqual(@as(u32, 0), unit.readOffset(flag.reg.bcst) & flag.bcst.bfref);
}
