//! Covers src/chip/periph/i3c/i3c_regs.zig: what a read or a store of each width names
//! inside one of the I3C channel's register words, and the three things the
//! block used to get wrong when the access was narrower than the register.
const std = @import("std");
const ra8 = @import("ra8");

const bus = ra8.chip.periph.riic_bus;
const flag = ra8.chip.periph.i3c_flags;
const i3c = ra8.chip.periph.i3c;
const regs = ra8.chip.periph.i3c_regs;

fn at(offset: u32, width: u3) regs.Access {
    return regs.Access.of(offset, width);
}

/// Read `width` bytes from the live block, the way the bus asks for them.
fn readAt(unit: *i3c.I3c, offset: u32, width: u3) u32 {
    return unit.read(flag.win_base +% offset, width);
}

fn writeAt(unit: *i3c.I3c, offset: u32, width: u3, value: u32) void {
    unit.write(flag.win_base +% offset, width, value);
}

test "an access knows the word it lands in and the lane it starts at" {
    const byte1 = at(flag.reg.bst + 1, 1);
    try std.testing.expectEqual(flag.reg.bst, byte1.word);
    try std.testing.expectEqual(@as(u32, 1), byte1.at);
    try std.testing.expectEqual(flag.reg.bst / 4, byte1.index());
    try std.testing.expectEqual(@as(u32, 0x0000_FF00), byte1.mask());
    try std.testing.expect(byte1.names(1));
    try std.testing.expect(!byte1.names(0));
}

test "a word access names every lane and a halfword names two" {
    try std.testing.expectEqual(~@as(u32, 0), at(flag.reg.bst, 4).mask());
    try std.testing.expectEqual(@as(u32, 0x0000_FFFF), at(flag.reg.bst, 2).mask());
    try std.testing.expectEqual(@as(u32, 0xFFFF_0000), at(flag.reg.bst + 2, 2).mask());
}

test "a read is cut to the lanes it names" {
    const high = at(flag.reg.bst + 2, 1);
    try std.testing.expectEqual(@as(u32, 0x0001), high.cut(0x0001_0000));
    try std.testing.expectEqual(@as(u32, 0xAA), at(flag.reg.bst + 3, 1).cut(0xAABB_CCDD));
    try std.testing.expectEqual(@as(u32, 0xAABB_CCDD), at(flag.reg.bst, 4).cut(0xAABB_CCDD));
}

test "a narrow store leaves the lanes it does not name" {
    const lane2 = at(flag.reg.msdvad + 2, 1);
    try std.testing.expectEqual(@as(u32, 0xAA99_CCDD), lane2.fold(0xAABB_CCDD, 0x99));
}

test "a clearing store carries ones outside the lanes it named" {
    // A byte ack at lane 0 writing zero clears only the bottom eight bits.
    try std.testing.expectEqual(@as(u32, 0xFFFF_FF00), at(flag.reg.bst, 1).clearing(0x00));
    // The same store one lane up.
    try std.testing.expectEqual(@as(u32, 0xFFFF_00FF), at(flag.reg.bst + 1, 1).clearing(0x00));
    // A word store names everything, so it is the value itself.
    try std.testing.expectEqual(@as(u32, 0x0000_0001), at(flag.reg.bst, 4).clearing(0x0000_0001));
}

test "only an access reaching the low lane moves a data byte" {
    try std.testing.expect(at(flag.reg.ntdtbp0, 1).carriesData());
    try std.testing.expect(at(flag.reg.ntdtbp0, 4).carriesData());
    try std.testing.expect(!at(flag.reg.ntdtbp0 + 1, 1).carriesData());
    try std.testing.expect(!at(flag.reg.ntdtbp0 + 2, 2).carriesData());
}

test "an offset past the window is not this block's" {
    try std.testing.expect(regs.inside(flag.win_span - 1));
    try std.testing.expect(!regs.inside(flag.win_span));
}

test "a byte read of BST lane 1 answers TENDF, not the low byte" {
    var unit = i3c.I3c{};
    unit.bst = flag.bst.stcnddf | flag.bst.tendf;
    // Lane 0 carries the condition flags, lane 1 carries TENDF at b8.
    try std.testing.expectEqual(flag.bst.stcnddf, readAt(&unit, flag.reg.bst, 1));
    try std.testing.expectEqual(@as(u32, 1), readAt(&unit, flag.reg.bst + 1, 1));
    // And the halfword read that spans both answers both.
    try std.testing.expectEqual(
        flag.bst.stcnddf | flag.bst.tendf,
        readAt(&unit, flag.reg.bst, 2),
    );
}

test "a byte ack of the START flag leaves the flags in the lanes above it" {
    var unit = i3c.I3c{};
    unit.bst = flag.bst.stcnddf | flag.bst.tendf | flag.bst.alf | flag.bst.todf;
    // The handler acknowledges STCNDDF alone: write-0-to-clear, byte wide.
    writeAt(&unit, flag.reg.bst, 1, ~flag.bst.stcnddf & 0xFF);
    try std.testing.expectEqual(
        flag.bst.tendf | flag.bst.alf | flag.bst.todf,
        unit.bst,
    );
}

test "a byte ack one lane up clears only TENDF" {
    var unit = i3c.I3c{};
    unit.bst = flag.bst.stcnddf | flag.bst.tendf | flag.bst.alf;
    writeAt(&unit, flag.reg.bst + 1, 1, 0x00);
    try std.testing.expectEqual(flag.bst.stcnddf | flag.bst.alf, unit.bst);
}

test "a word ack still clears every flag it writes zero at" {
    var unit = i3c.I3c{};
    unit.bst = flag.bst.stcnddf | flag.bst.tendf | flag.bst.alf;
    writeAt(&unit, flag.reg.bst, 4, flag.bst.alf);
    try std.testing.expectEqual(flag.bst.alf, unit.bst);
}

test "a narrow store into a shadowed register keeps the rest of the word" {
    var unit = i3c.I3c{};
    const spare: u32 = 0x100; // a configuration word this model only reflects
    writeAt(&unit, spare, 4, 0xAABB_CCDD);
    writeAt(&unit, spare + 2, 1, 0x11);
    try std.testing.expectEqual(@as(u32, 0xAA11_CCDD), readAt(&unit, spare, 4));
    try std.testing.expectEqual(@as(u32, 0x11), readAt(&unit, spare + 2, 1));
    try std.testing.expectEqual(@as(u32, 0xAA11), readAt(&unit, spare + 2, 2));
}

test "a byte store of the START request still opens a transaction" {
    var unit = i3c.I3c{};
    writeAt(&unit, flag.reg.cndctl, 1, flag.cndctl.stcnd);
    try std.testing.expectEqual(flag.bst.stcnddf, unit.bst & flag.bst.stcnddf);
    try std.testing.expectEqual(@as(u32, 0), readAt(&unit, flag.reg.bcst, 1));
}

test "the data port serves its byte on the low lane and nowhere else" {
    var unit = i3c.I3c{};
    var part = Echo{ .reply = &[_]u8{ 0x5A, 0xA5 } };
    try unit.attachDevice(part.device(0x38));
    writeAt(&unit, flag.reg.cndctl, 1, flag.cndctl.stcnd);
    writeAt(&unit, flag.reg.ntdtbp0, 1, (0x38 << 1) | 1);
    _ = readAt(&unit, flag.reg.ntdtbp0, 1); // the priming read
    // A read that never reaches byte 0 takes nothing off the line.
    try std.testing.expectEqual(@as(u32, 0), readAt(&unit, flag.reg.ntdtbp0 + 2, 1));
    try std.testing.expectEqual(@as(u32, 0x5A), readAt(&unit, flag.reg.ntdtbp0, 1));
    try std.testing.expectEqual(@as(u32, 0xA5), readAt(&unit, flag.reg.ntdtbp0, 1));
}

/// A part that answers with a fixed reply and remembers what it was told.
const Echo = struct {
    reply: []const u8 = &[_]u8{},
    heard: [8]u8 = @splat(0),
    heard_len: usize = 0,

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
        _ = context;
    }

    fn device(self: *Echo, address: u7) bus.Device {
        return .{
            .address = address,
            .context = self,
            .writeFn = write,
            .readFn = read,
            .stopFn = ended,
        };
    }
};
