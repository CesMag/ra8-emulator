//! Covers src/chip/periph/dac/output.zig, and the gate and placement it puts on
//! src/chip/periph/dac/dac.zig.
const std = @import("std");
const ra8 = @import("ra8");
const dac = ra8.chip.periph.dac;
const output = ra8.chip.periph.dac_output;

const ch0 = dac.channelAddress(0);

fn unit() dac.Dac {
    return dac.Dac.init();
}

/// Turn a channel on the way a driver does: a read-modify-write of DACR0.
fn enable(block: *dac.Dac, base: u32) void {
    const current = block.read(base + dac.off_dacr0, 4);
    block.write(base + dac.off_dacr0, 4, current | dac.field.dacen);
}

test "a channel drives only when it is enabled and its output is not disabled" {
    try std.testing.expect(!output.driving(0));
    try std.testing.expect(output.driving(output.mask.dacen));
    try std.testing.expect(!output.driving(output.mask.daoutdis));
    try std.testing.expect(!output.driving(output.mask.dacen | output.mask.daoutdis));
}

test "DAE rides along without changing whether the channel drives" {
    try std.testing.expect(output.driving(output.mask.dacen | output.mask.dae));
}

test "DPSEL picks where the twelve bits sit" {
    try std.testing.expectEqual(output.Placement.right, output.Placement.of(0));
    try std.testing.expectEqual(output.Placement.left, output.Placement.of(output.mask.dpsel));
    try std.testing.expectEqual(@as(u16, 0x0ABC), output.Placement.right.code(0x0ABC));
    try std.testing.expectEqual(@as(u16, 0x0ABC), output.Placement.left.code(0xABC0));
}

test "each placement holds only the bits silicon has" {
    try std.testing.expectEqual(@as(u16, 0x0FFF), output.Placement.right.held());
    try std.testing.expectEqual(@as(u16, 0xFFF0), output.Placement.left.held());
}

test "a code written with DAOUTDIS set latches but is not an output" {
    var block = unit();
    block.write(ch0 + dac.off_dacr0, 4, dac.field.dacen | dac.field.daoutdis);
    block.write(ch0 + dac.off_dadr, 2, 0x0ABC);
    try std.testing.expectEqual(@as(u32, 0x0ABC), block.read(ch0 + dac.off_dadr, 2));
    try std.testing.expectEqual(@as(u32, 0), block.channels[0].outputs);
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].blocked);
    try std.testing.expectEqual(@as(u16, 0), block.channels[0].peak);
    try std.testing.expect(!block.quiet());
}

test "clearing DAOUTDIS lets the next code through" {
    var block = unit();
    block.write(ch0 + dac.off_dacr0, 4, dac.field.dacen | dac.field.daoutdis);
    block.write(ch0 + dac.off_dadr, 2, 0x0111);
    block.write(ch0 + dac.off_dacr0, 4, dac.field.dacen);
    block.write(ch0 + dac.off_dadr, 2, 0x0222);
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].outputs);
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].blocked);
    try std.testing.expectEqual(@as(u16, 0x0222), block.channels[0].peak);
}

test "a shut-down channel counts the code as dark, not blocked" {
    var block = unit();
    block.write(ch0 + dac.off_dacr0, 4, dac.field.daoutdis);
    block.write(ch0 + dac.off_dadr, 2, 0x0333);
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].dark);
    try std.testing.expectEqual(@as(u32, 0), block.channels[0].blocked);
}

test "a left-justified channel reads its code from the top of DADR" {
    var block = unit();
    block.write(ch0 + dac.off_dacr1, 4, output.mask.dpsel);
    enable(&block, ch0);
    block.write(ch0 + dac.off_dadr, 2, 0xABCD);
    try std.testing.expectEqual(@as(u16, 0x0ABC), block.channels[0].code());
    try std.testing.expectEqual(@as(u16, 0x0ABC), block.channels[0].peak);
    try std.testing.expectEqual(@as(u32, 0xABC0), block.read(ch0 + dac.off_dadr, 2));
}

test "a right-justified channel keeps taking the low twelve" {
    var block = unit();
    enable(&block, ch0);
    block.write(ch0 + dac.off_dadr, 2, 0xABCD);
    try std.testing.expectEqual(@as(u16, 0x0BCD), block.channels[0].code());
    try std.testing.expectEqual(@as(u32, 0x0BCD), block.read(ch0 + dac.off_dadr, 2));
}

test "DACR1 reads back whole, DPSEL and all" {
    var block = unit();
    block.write(ch0 + dac.off_dacr1, 4, 0x0001_5A5A);
    try std.testing.expectEqual(@as(u32, 0x0001_5A5A), block.read(ch0 + dac.off_dacr1, 4));
    try std.testing.expectEqual(output.Placement.left, block.channels[0].placement());
}
