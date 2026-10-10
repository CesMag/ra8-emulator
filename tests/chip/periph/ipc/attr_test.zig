//! IPCSAR / IPCPAR: the attribution pair, and the PRC4 gate in front of it.
const std = @import("std");
const ra8 = @import("ra8");
const attr = ra8.chip.periph.ipc.attr;
const prcr = ra8.chip.periph.prcr;

const sar_addr = attr.win_base + attr.off.sar;
const par_addr = attr.win_base + attr.off.par;

/// A gate with PRC4 open, the state the Secure boot writes these words in.
fn opened() prcr.Prcr {
    var gate = prcr.Prcr.init();
    gate.write(prcr.win_base, 2, prcr.unlockWord(prcr.group.sar));
    return gate;
}

test "the pair is Secure and Privileged out of reset" {
    var gate = prcr.Prcr.init();
    var unit = attr.Attribution.init(&gate);
    try std.testing.expectEqual(@as(u32, 0), unit.read(sar_addr, 4));
    try std.testing.expectEqual(@as(u32, 0), unit.read(par_addr, 4));
    try std.testing.expectEqual(@as(usize, 0), unit.givenAway());
    for (0..attr.field.channels) |channel| {
        try std.testing.expectEqual(attr.World.secure, unit.worldOf(channel));
        try std.testing.expectEqual(attr.Access.privileged, unit.accessOf(channel));
    }
}

test "a fresh unit is quiet" {
    var gate = prcr.Prcr.init();
    const unit = attr.Attribution.init(&gate);
    try std.testing.expect(unit.quiet());
}

test "with PRC4 open the words land and read back" {
    var gate = opened();
    var unit = attr.Attribution.init(&gate);
    unit.write(sar_addr, 4, 0x0000_0005);
    unit.write(par_addr, 4, 0x0000_0001);
    try std.testing.expectEqual(@as(u32, 0x0000_0005), unit.read(sar_addr, 4));
    try std.testing.expectEqual(@as(u32, 0x0000_0001), unit.read(par_addr, 4));
    try std.testing.expectEqual(@as(u32, 2), unit.writes);
    try std.testing.expectEqual(@as(u32, 0), unit.locked_writes);
}

test "a set bit is a channel given away, a clear one a channel kept" {
    var gate = opened();
    var unit = attr.Attribution.init(&gate);
    // Channels 0 and 2 Non-Secure, 2 also Unprivileged.
    unit.write(sar_addr, 4, 0x0000_0005);
    unit.write(par_addr, 4, 0x0000_0004);
    try std.testing.expectEqual(@as(usize, 2), unit.givenAway());
    try std.testing.expectEqual(attr.World.non_secure, unit.worldOf(0));
    try std.testing.expectEqual(attr.World.secure, unit.worldOf(1));
    try std.testing.expectEqual(attr.World.non_secure, unit.worldOf(2));
    try std.testing.expectEqual(attr.Access.privileged, unit.accessOf(0));
    try std.testing.expectEqual(attr.Access.unprivileged, unit.accessOf(2));
}

test "with PRC4 shut the store is discarded and counted" {
    var gate = prcr.Prcr.init();
    var unit = attr.Attribution.init(&gate);
    unit.write(sar_addr, 4, 0x0000_000F);
    try std.testing.expectEqual(@as(u32, 0), unit.read(sar_addr, 4));
    try std.testing.expectEqual(@as(usize, 0), unit.givenAway());
    try std.testing.expectEqual(@as(u32, 1), unit.locked_writes);
    try std.testing.expectEqual(@as(u32, 0), unit.writes);
    try std.testing.expect(!unit.quiet());
}

test "relocking PRC4 shuts the gate again" {
    var gate = opened();
    var unit = attr.Attribution.init(&gate);
    unit.write(sar_addr, 4, 0x0000_0005);
    gate.write(prcr.win_base, 2, prcr.unlockWord(0));
    unit.write(sar_addr, 4, 0x0000_000F);
    try std.testing.expectEqual(@as(u32, 0x0000_0005), unit.read(sar_addr, 4));
    try std.testing.expectEqual(@as(u32, 1), unit.locked_writes);
}

test "another group open is not PRC4" {
    var gate = prcr.Prcr.init();
    gate.write(prcr.win_base, 2, prcr.unlockWord(prcr.group.lpm));
    var unit = attr.Attribution.init(&gate);
    unit.write(sar_addr, 4, 0x0000_000F);
    try std.testing.expectEqual(@as(u32, 0), unit.read(sar_addr, 4));
    try std.testing.expectEqual(@as(u32, 1), unit.locked_writes);
}

test "a read is never gated" {
    var gate = opened();
    var unit = attr.Attribution.init(&gate);
    unit.write(sar_addr, 4, 0x0000_0003);
    gate.write(prcr.win_base, 2, prcr.unlockWord(0));
    try std.testing.expectEqual(@as(u32, 0x0000_0003), unit.read(sar_addr, 4));
}

test "a narrow access names its own lanes" {
    var gate = opened();
    var unit = attr.Attribution.init(&gate);
    unit.write(sar_addr, 4, 0xAABB_CCDD);
    try std.testing.expectEqual(@as(u32, 0xDD), unit.read(sar_addr, 1));
    try std.testing.expectEqual(@as(u32, 0xCC), unit.read(sar_addr + 1, 1));
    try std.testing.expectEqual(@as(u32, 0xAABB), unit.read(sar_addr + 2, 2));
    unit.write(sar_addr + 1, 1, 0x11);
    try std.testing.expectEqual(@as(u32, 0xAABB_11DD), unit.read(sar_addr, 4));
}

test "the two words do not bleed into each other" {
    var gate = opened();
    var unit = attr.Attribution.init(&gate);
    unit.write(sar_addr, 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), unit.read(par_addr, 4));
    unit.write(par_addr, 4, 0x1234_5678);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), unit.read(sar_addr, 4));
}

test "an unwired unit accepts nothing" {
    var unit = attr.Attribution{};
    unit.write(sar_addr, 4, 0x0000_000F);
    try std.testing.expectEqual(@as(u32, 0), unit.read(sar_addr, 4));
    try std.testing.expectEqual(@as(u32, 1), unit.locked_writes);
}

test "the block answers for the window it claims" {
    var gate = opened();
    var unit = attr.Attribution.init(&gate);
    const block = unit.block();
    try std.testing.expectEqual(attr.win_base, block.base);
    try std.testing.expectEqual(attr.win_span, block.size);
    try std.testing.expect(block.covers(par_addr));
    try std.testing.expect(!block.covers(attr.win_base + attr.win_span));
    block.writeFn(block.context, sar_addr, 4, 0x0000_0002);
    try std.testing.expectEqual(@as(u32, 0x0000_0002), block.readFn(block.context, sar_addr, 4));
}
