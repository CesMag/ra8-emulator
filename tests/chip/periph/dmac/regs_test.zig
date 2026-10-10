//! Covers src/chip/periph/dmac/regs.zig: the DMAC channel register map, and what a
//! read or a store of each width names inside one of its words.
const std = @import("std");
const ra8 = @import("ra8");

const dmac = ra8.chip.periph.dmac;
const regs = ra8.chip.periph.dmac_regs;
const lanes = ra8.chip.periph.lanes;

/// A channel with every register carrying a value that names itself, so a
/// lane answering out of the wrong register is visible in the value.
fn programmed() dmac.Channel {
    return .{
        .dmsar = 0x2208_0400,
        .dmdar = 0x2208_0500,
        .dmcra = 0x0004_0008,
        .dmcrb = 0x0000_0003,
        .dmtmd = 0x1234,
        .dmamd = 0x5678,
        .dmint = regs.field.dtie,
        .dmcnt = regs.field.dte,
        .dmsts = regs.field.dtif,
    };
}

/// Read `width` bytes starting at `local`, the way the bus asks for them.
fn readAt(channel: *const dmac.Channel, local: u32, width: u3) u32 {
    const value = regs.wordValue(channel, lanes.word(local));
    return lanes.part(value, lanes.lane(local), width);
}

/// Store `value` of `width` bytes at `local` and answer what the store asked
/// the controller for, if anything.
fn writeAt(channel: *dmac.Channel, local: u32, width: u3, value: u32) ?regs.Request {
    const base = lanes.word(local);
    const at = lanes.lane(local);
    const merged = lanes.merge(regs.wordValue(channel, base), at, width, value);
    return regs.apply(channel, base, merged, lanes.named(at, width));
}

test "the top half of a 32-bit register answers where it sits" {
    const channel = programmed();
    try std.testing.expectEqual(@as(u32, 0x2208), readAt(&channel, regs.off.dmsar + 2, 2));
    try std.testing.expectEqual(@as(u32, 0x0400), readAt(&channel, regs.off.dmsar, 2));
    try std.testing.expectEqual(@as(u32, 0x22), readAt(&channel, regs.off.dmsar + 3, 1));
}

test "a word read of the control registers carries all three of them" {
    const channel = programmed();
    const word = readAt(&channel, regs.off.dmcnt, 4);
    try std.testing.expectEqual(@as(u32, regs.field.dte), word & 0xFF);
    // DMREQ holds nothing to read back: the request is spent in its store.
    try std.testing.expectEqual(@as(u32, 0), (word >> 8) & 0xFF);
    try std.testing.expectEqual(@as(u32, regs.field.dtif), (word >> 16) & 0xFF);
}

test "DMINT answers in byte 3 and DMTMD in the half below it" {
    const channel = programmed();
    try std.testing.expectEqual(@as(u32, regs.field.dtie), readAt(&channel, regs.off.dmint, 1));
    try std.testing.expectEqual(@as(u32, 0x1234), readAt(&channel, regs.off.dmtmd, 2));
}

test "a lane no register occupies reads zero" {
    const channel = programmed();
    try std.testing.expectEqual(@as(u32, 0), readAt(&channel, regs.off.dmtmd + 2, 1));
    try std.testing.expectEqual(@as(u32, 0), readAt(&channel, regs.off.dmamd + 2, 2));
    try std.testing.expectEqual(@as(u32, 0), readAt(&channel, regs.off.dmsts + 1, 1));
}

test "a halfword store at DMCNT arms the channel and asks for the transfer" {
    var channel = dmac.Channel{ .dmcra = 8 };
    const asked = writeAt(&channel, regs.off.dmcnt, 2, regs.field.dte | (@as(u32, regs.field.swreq) << 8));
    try std.testing.expect(channel.armed());
    try std.testing.expect(asked != null);
    try std.testing.expect(!asked.?.continuous);
}

test "CLRS in the same store asks for a continuous request" {
    var channel = dmac.Channel{ .dmcra = 8 };
    const swreq: u32 = regs.field.swreq | regs.field.clrs;
    const asked = writeAt(&channel, regs.off.dmcnt, 2, regs.field.dte | (swreq << 8));
    try std.testing.expect(asked.?.continuous);
}

test "a byte store into DMREQ alone still asks, and arms nothing" {
    var channel = dmac.Channel{};
    const asked = writeAt(&channel, regs.off.dmreq, 1, regs.field.swreq);
    try std.testing.expect(asked != null);
    try std.testing.expect(!channel.armed());
}

test "a store that names DMREQ without SWREQ asks for nothing" {
    var channel = dmac.Channel{};
    try std.testing.expect(writeAt(&channel, regs.off.dmreq, 1, regs.field.clrs) == null);
}

test "a byte store into DMINT leaves DMTMD under it alone" {
    var channel = programmed();
    _ = writeAt(&channel, regs.off.dmint, 1, regs.field.dtie);
    try std.testing.expectEqual(@as(u16, 0x1234), channel.dmtmd);
    try std.testing.expectEqual(@as(u8, regs.field.dtie), channel.dmint);
}

test "clearing DTIF leaves the arming byte two lanes down where it was" {
    var channel = programmed();
    _ = writeAt(&channel, regs.off.dmsts, 1, ~@as(u32, regs.field.dtif));
    try std.testing.expectEqual(@as(u8, 0), channel.dmsts & regs.field.dtif);
    try std.testing.expectEqual(@as(u8, regs.field.dte), channel.dmcnt);
}

test "a store into a reserved lane holds nothing" {
    var channel = programmed();
    _ = writeAt(&channel, regs.off.dmtmd + 2, 1, 0xFF);
    try std.testing.expectEqual(@as(u16, 0x1234), channel.dmtmd);
    try std.testing.expectEqual(@as(u8, regs.field.dtie), channel.dmint);
}

test "a narrow store into an address register keeps the bytes it does not name" {
    var channel = programmed();
    _ = writeAt(&channel, regs.off.dmsar + 2, 2, 0x2209);
    try std.testing.expectEqual(@as(u32, 0x2209_0400), channel.dmsar);
}
