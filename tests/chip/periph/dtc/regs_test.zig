//! Every byte of the DTC window belongs to one register, and an access is
//! the bytes it names.
const std = @import("std");
const ra8 = @import("ra8");
const dtc = ra8.chip.periph.dtc;
const regs = ra8.chip.periph.dtc.regs;

fn unit() dtc.Dtc {
    return dtc.Dtc.init();
}

test "each register owns its own bytes, and the gaps own none" {
    try std.testing.expectEqual(regs.Reg.dtccr, regs.owner(0x00).?.reg);
    try std.testing.expectEqual(@as(u32, 0), regs.owner(0x00).?.index);
    try std.testing.expect(regs.owner(0x01) == null);
    try std.testing.expect(regs.owner(0x03) == null);
    try std.testing.expectEqual(regs.Reg.dtcvbr, regs.owner(0x04).?.reg);
    try std.testing.expectEqual(@as(u32, 3), regs.owner(0x07).?.index);
    try std.testing.expect(regs.owner(0x08) == null);
    try std.testing.expect(regs.owner(0x0B) == null);
    try std.testing.expectEqual(regs.Reg.dtcst, regs.owner(0x0C).?.reg);
    try std.testing.expect(regs.owner(0x0D) == null);
    try std.testing.expectEqual(regs.Reg.dtcsts, regs.owner(0x0E).?.reg);
    try std.testing.expectEqual(@as(u32, 1), regs.owner(0x0F).?.index);
    try std.testing.expect(regs.owner(0x10) == null);
}

test "only the controller writes DTCSTS" {
    try std.testing.expect(regs.writable(.dtccr));
    try std.testing.expect(regs.writable(.dtcvbr));
    try std.testing.expect(regs.writable(.dtcst));
    try std.testing.expect(!regs.writable(.dtcsts));
}

test "the vector base can be programmed in two halfword stores" {
    var block = unit();
    block.write(dtc.win_base + dtc.off.dtcvbr, 2, 0x4000);
    block.write(dtc.win_base + dtc.off.dtcvbr + 2, 2, 0x2000);
    try std.testing.expectEqual(
        @as(u32, 0x2000_4000),
        block.read(dtc.win_base + dtc.off.dtcvbr, 4),
    );
}

test "a narrow read of the vector base answers the lane it names" {
    var block = unit();
    block.write(dtc.win_base + dtc.off.dtcvbr, 4, 0x2000_4080);
    try std.testing.expectEqual(
        @as(u32, 0x80),
        block.read(dtc.win_base + dtc.off.dtcvbr, 1),
    );
    try std.testing.expectEqual(
        @as(u32, 0x2000),
        block.read(dtc.win_base + dtc.off.dtcvbr + 2, 2),
    );
    try std.testing.expectEqual(
        @as(u32, 0x20),
        block.read(dtc.win_base + dtc.off.dtcvbr + 3, 1),
    );
}

test "a word read at DTCST answers the start bit and the status word" {
    var block = unit();
    block.write(dtc.win_base + dtc.off.dtcst, 1, dtc.field.start);
    block.dtcsts = dtc.field.active | 0x12;
    const pair = block.read(dtc.win_base + dtc.off.dtcst, 4);
    try std.testing.expectEqual(@as(u32, dtc.field.start), pair & 0xFF);
    try std.testing.expectEqual(
        @as(u32, dtc.field.active | 0x12),
        pair >> 16,
    );
}

test "the ACT byte is readable on its own" {
    var block = unit();
    block.dtcsts = dtc.field.active | 0x34;
    try std.testing.expectEqual(
        @as(u32, 0x34),
        block.read(dtc.win_base + dtc.off.dtcsts, 1),
    );
    try std.testing.expectEqual(
        @as(u32, 0x80),
        block.read(dtc.win_base + dtc.off.dtcsts + 1, 1),
    );
}

test "a store the firmware makes at DTCSTS changes nothing" {
    var block = unit();
    block.dtcsts = dtc.field.active | 0x56;
    block.write(dtc.win_base + dtc.off.dtcsts, 2, 0);
    block.write(dtc.win_base + dtc.off.dtcst, 4, 0x0000_0001);
    try std.testing.expectEqual(
        @as(u32, dtc.field.active | 0x56),
        block.read(dtc.win_base + dtc.off.dtcsts, 2),
    );
    try std.testing.expectEqual(
        @as(u32, dtc.field.start),
        block.read(dtc.win_base + dtc.off.dtcst, 1),
    );
}

test "a byte a reserved gap owns holds nothing and reads zero" {
    var block = unit();
    block.write(dtc.win_base + 0x0D, 1, 0xFF);
    try std.testing.expectEqual(@as(u32, 0), block.read(dtc.win_base + 0x0D, 1));
    block.write(dtc.win_base + 0x01, 1, 0xFF);
    try std.testing.expectEqual(@as(u32, 0), block.read(dtc.win_base + 0x01, 1));
    try std.testing.expectEqual(@as(u32, 0), block.read(dtc.win_base + dtc.off.dtccr, 1));
}

test "a whole-word read at DTCCR is still DTCCR alone" {
    var block = unit();
    block.write(dtc.win_base + dtc.off.dtccr, 1, 0x08);
    try std.testing.expectEqual(
        @as(u32, 0x08),
        block.read(dtc.win_base + dtc.off.dtccr, 4),
    );
}

test "the register map matches the block's own offsets" {
    try std.testing.expectEqual(dtc.off.dtccr, regs.at.dtccr);
    try std.testing.expectEqual(dtc.off.dtcvbr, regs.at.dtcvbr);
    try std.testing.expectEqual(dtc.off.dtcst, regs.at.dtcst);
    try std.testing.expectEqual(dtc.off.dtcsts, regs.at.dtcsts);
}

test "CPU1 reaches DTC1 and CPU0 reaches DTC0 at the same address" {
    var dtc0 = unit();
    var dtc1 = unit();
    var issuer: ra8.chip.periph.registry.Issuer = .cpu0;
    dtc0.twin = &dtc1;
    dtc0.issuer = &issuer;
    const window = dtc0.block();
    const vbr = dtc.win_base + regs.at.dtcvbr;

    issuer = .cpu1;
    window.writeFn(window.context, vbr, 4, 0x2200_0400);
    try std.testing.expectEqual(@as(u32, 0x2200_0400), dtc1.dtcvbr);
    try std.testing.expectEqual(@as(u32, 0), dtc0.dtcvbr);

    issuer = .cpu0;
    try std.testing.expectEqual(@as(u32, 0), window.readFn(window.context, vbr, 4));
    window.writeFn(window.context, vbr, 4, 0x2200_0800);
    try std.testing.expectEqual(@as(u32, 0x2200_0800), dtc0.dtcvbr);
    try std.testing.expectEqual(@as(u32, 0x2200_0400), dtc1.dtcvbr);
}

test "with no twin the window is DTC0 whoever asks" {
    var dtc0 = unit();
    var issuer: ra8.chip.periph.registry.Issuer = .cpu1;
    dtc0.issuer = &issuer;
    const window = dtc0.block();
    window.writeFn(window.context, dtc.win_base + regs.at.dtcvbr, 4, 0x2200_0400);
    try std.testing.expectEqual(@as(u32, 0x2200_0400), dtc0.dtcvbr);
}
