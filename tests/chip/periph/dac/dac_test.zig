//! Covers src/chip/periph/dac.zig.
const std = @import("std");
const dac = @import("ra8").chip.periph.dac;

const ch0 = dac.channelAddress(0);
const ch1 = dac.channelAddress(1);

fn unit() dac.Dac {
    return dac.Dac.init();
}

/// Turn a channel on the way a driver does: a read-modify-write of DACR0.
fn enable(block: *dac.Dac, base: u32) void {
    const current = block.read(base + dac.off_dacr0, 4);
    block.write(base + dac.off_dacr0, 4, current | dac.field.dacen);
}

test "a fresh channel is off, empty and quiet" {
    var block = unit();
    try std.testing.expectEqual(@as(u32, 0), block.read(ch0 + dac.off_dadr, 4));
    try std.testing.expect(!block.channels[0].enabled());
    try std.testing.expect(block.quiet());
}

test "an enabled channel takes a code and reads it back" {
    var block = unit();
    enable(&block, ch0);
    block.write(ch0 + dac.off_dadr, 2, 0x0ABC);
    try std.testing.expectEqual(@as(u32, 0x0ABC), block.read(ch0 + dac.off_dadr, 2));
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].outputs);
    try std.testing.expectEqual(@as(u16, 0x0ABC), block.channels[0].peak);
    try std.testing.expectEqual(@as(u32, 0), block.channels[0].dark);
}

test "DADR is twelve bits: the rest of the store does not read back" {
    var block = unit();
    enable(&block, ch0);
    block.write(ch0 + dac.off_dadr, 4, 0xF123);
    try std.testing.expectEqual(@as(u32, 0x0123), block.read(ch0 + dac.off_dadr, 4));
    try std.testing.expectEqual(@as(u16, 0x0123), block.channels[0].code());
}

test "a code written with DACEN clear is stored but is not an output" {
    var block = unit();
    block.write(ch0 + dac.off_dadr, 2, 0x0FFF);
    try std.testing.expectEqual(@as(u32, 0x0FFF), block.read(ch0 + dac.off_dadr, 2));
    try std.testing.expectEqual(@as(u32, 0), block.channels[0].outputs);
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].dark);
    try std.testing.expectEqual(@as(u16, 0), block.channels[0].peak);
    try std.testing.expect(!block.quiet());
}

test "a code staged before the enable counts from the next store on" {
    var block = unit();
    block.write(ch0 + dac.off_dadr, 2, 0x0100);
    enable(&block, ch0);
    try std.testing.expectEqual(@as(u32, 0x0100), block.read(ch0 + dac.off_dadr, 2));
    block.write(ch0 + dac.off_dadr, 2, 0x0200);
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].outputs);
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].dark);
}

test "peak keeps the largest code, not the last" {
    var block = unit();
    enable(&block, ch0);
    block.write(ch0 + dac.off_dadr, 2, 0x0800);
    block.write(ch0 + dac.off_dadr, 2, 0x0010);
    try std.testing.expectEqual(@as(u16, 0x0800), block.channels[0].peak);
    try std.testing.expectEqual(@as(u16, 0x0010), block.channels[0].code());
    try std.testing.expectEqual(@as(u32, 2), block.channels[0].outputs);
}

test "a byte store to DACEN leaves the rest of DACR0 alone" {
    var block = unit();
    block.write(ch0 + dac.off_dacr0, 4, 0x5A5A_5A00);
    block.write(ch0 + dac.off_dacr0, 1, dac.field.dacen);
    try std.testing.expectEqual(
        @as(u32, 0x5A5A_5A01),
        block.read(ch0 + dac.off_dacr0, 4),
    );
    try std.testing.expect(block.channels[0].enabled());
}

test "a byte store to the high half of DADR keeps the low half" {
    var block = unit();
    enable(&block, ch0);
    block.write(ch0 + dac.off_dadr, 2, 0x0055);
    block.write(ch0 + dac.off_dadr + 1, 1, 0x0A);
    try std.testing.expectEqual(@as(u32, 0x0A55), block.read(ch0 + dac.off_dadr, 2));
}

test "the two channels are separate" {
    var block = unit();
    enable(&block, ch1);
    block.write(ch1 + dac.off_dadr, 2, 0x0333);
    try std.testing.expectEqual(@as(u32, 0), block.read(ch0 + dac.off_dadr, 2));
    try std.testing.expectEqual(@as(u32, 0x0333), block.read(ch1 + dac.off_dadr, 2));
    try std.testing.expect(block.channels[0].quiet());
    try std.testing.expect(!block.channels[1].quiet());
}

test "an uninterpreted register in the window reads back what was written" {
    var block = unit();
    block.write(ch0 + 0x0C, 4, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), block.read(ch0 + 0x0C, 4));
    try std.testing.expect(block.quiet());
}

test "the block descriptor covers both channels and nothing else" {
    var block = unit();
    const descriptor = block.block();
    try std.testing.expectEqual(dac.win_base, descriptor.base);
    try std.testing.expectEqual(dac.win_span, descriptor.size);
    try std.testing.expect(descriptor.covers(ch1 + 0xFF));
    try std.testing.expect(!descriptor.covers(dac.win_base + dac.win_span));
}

test "a store in the reserved halfword above DADR is not a code" {
    var block = unit();
    enable(&block, ch0);
    block.write(ch0 + dac.off_dadr, 2, 0x0ABC);
    block.write(ch0 + dac.off_dadr + dac.data_bytes, 2, 0xFFFF);
    try std.testing.expectEqual(@as(u32, 0x0ABC), block.read(ch0 + dac.off_dadr, 2));
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].outputs);
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].above_data);
}

test "the reserved halfword above DADR reads zero" {
    var block = unit();
    enable(&block, ch0);
    block.write(ch0 + dac.off_dadr, 2, 0x0FFF);
    try std.testing.expectEqual(@as(u32, 0), block.read(ch0 + dac.off_dadr + 2, 2));
    try std.testing.expectEqual(@as(u32, 0), block.read(ch0 + dac.off_dadr + 3, 1));
}

test "a byte store above DADR moves no peak on an enabled channel" {
    var block = unit();
    enable(&block, ch0);
    block.write(ch0 + dac.off_dadr + 3, 1, 0xFF);
    try std.testing.expectEqual(@as(u16, 0), block.channels[0].peak);
    try std.testing.expectEqual(@as(u32, 0), block.channels[0].outputs);
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].above_data);
}

test "a store above DADR on a disabled channel is not a dark code" {
    var block = unit();
    block.write(ch0 + dac.off_dadr + 2, 2, 0x1234);
    try std.testing.expectEqual(@as(u32, 0), block.channels[0].dark);
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].above_data);
    try std.testing.expect(!block.channels[0].quiet());
}

test "a word store at DADR still carries the code it names" {
    var block = unit();
    enable(&block, ch0);
    block.write(ch0 + dac.off_dadr, 4, 0xFFFF_0777);
    try std.testing.expectEqual(@as(u32, 0x0777), block.read(ch0 + dac.off_dadr, 2));
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].outputs);
    try std.testing.expectEqual(@as(u32, 0), block.channels[0].above_data);
}

test "the reserved halfword is per channel" {
    var block = unit();
    block.write(ch1 + dac.off_dadr + 2, 2, 0x5555);
    try std.testing.expectEqual(@as(u32, 0), block.channels[0].above_data);
    try std.testing.expectEqual(@as(u32, 1), block.channels[1].above_data);
    try std.testing.expect(block.channels[0].quiet());
}
