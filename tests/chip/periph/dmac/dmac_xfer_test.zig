//! Covers src/chip/periph/dmac/dmac_xfer.zig: the channel plan a DMAC request is
//! decoded into, and the counts it latches.
const std = @import("std");
const ra8 = @import("ra8");
const xfer = ra8.chip.periph.dmac_xfer;

/// DMTMD for a given mode and width, the fields a driver actually sets.
fn tmd(mode: u16, width: u16) u16 {
    return mode << xfer.field.md_shift | width << xfer.field.sz_shift;
}

/// DMAMD for a source and destination address mode.
fn amd(source: u16, destination: u16) u16 {
    return source << xfer.field.sm_shift | destination << xfer.field.dm_shift;
}

/// The memcopy demo's channel: normal mode, byte units, both sides counting up.
const memcopy = xfer.Plan{
    .mode = .normal,
    .width = .byte,
    .source = .increment,
    .destination = .increment,
};

test "a plan decodes out of DMTMD and DMAMD" {
    const plan = xfer.Plan.decode(tmd(0, 2), amd(2, 2));
    try std.testing.expectEqual(xfer.Mode.normal, plan.mode);
    try std.testing.expectEqual(xfer.Width.word, plan.width);
    try std.testing.expectEqual(xfer.Addressing.increment, plan.source);
    try std.testing.expectEqual(xfer.Addressing.increment, plan.destination);
}

test "the source and destination modes come from different fields" {
    const plan = xfer.Plan.decode(tmd(0, 0), amd(3, 0));
    try std.testing.expectEqual(xfer.Addressing.decrement, plan.source);
    try std.testing.expectEqual(xfer.Addressing.fixed, plan.destination);
}

test "DMTMD.SZ picks the unit width" {
    try std.testing.expectEqual(@as(u32, 1), xfer.Plan.decode(tmd(0, 0), 0).unit());
    try std.testing.expectEqual(@as(u32, 2), xfer.Plan.decode(tmd(0, 1), 0).unit());
    try std.testing.expectEqual(@as(u32, 4), xfer.Plan.decode(tmd(0, 2), 0).unit());
}

test "a normal-mode request is worth one unit, not the whole count" {
    try std.testing.expectEqual(@as(u32, 1), memcopy.burst(64));
}

test "a block-mode request is worth one block" {
    const plan = xfer.Plan.decode(tmd(2, 0), amd(2, 2));
    try std.testing.expectEqual(@as(u32, 64), plan.burst(64));
}

test "an incrementing address steps forward by the unit width" {
    const plan = xfer.Plan.decode(tmd(0, 2), amd(2, 2));
    try std.testing.expectEqual(@as(i64, 4), plan.step(plan.source));
}

test "a decrementing address steps back, which dev treats as fixed" {
    const plan = xfer.Plan.decode(tmd(0, 1), amd(3, 3));
    try std.testing.expectEqual(@as(i64, -2), plan.step(plan.source));
    try std.testing.expectEqual(@as(i64, -2), plan.step(plan.destination));
}

test "a fixed address does not move, which is how a FIFO is fed" {
    const plan = xfer.Plan.decode(tmd(0, 0), amd(2, 0));
    try std.testing.expectEqual(@as(i64, 1), plan.step(plan.source));
    try std.testing.expectEqual(@as(i64, 0), plan.step(plan.destination));
}

test "repeat mode is declined rather than approximated" {
    const plan = xfer.Plan.decode(tmd(1, 0), amd(2, 2));
    try std.testing.expectEqual(xfer.Unsupported.repeat_mode, plan.unsupported().?);
}

test "the reserved mode and the reserved width are declined" {
    try std.testing.expectEqual(
        xfer.Unsupported.reserved_mode,
        xfer.Plan.decode(tmd(3, 0), 0).unsupported().?,
    );
    try std.testing.expectEqual(
        xfer.Unsupported.reserved_width,
        xfer.Plan.decode(tmd(0, 3), 0).unsupported().?,
    );
}

test "offset addressing is declined because DMOFR is never applied" {
    const plan = xfer.Plan.decode(tmd(0, 0), amd(1, 2));
    try std.testing.expectEqual(xfer.Unsupported.offset_addressing, plan.unsupported().?);
}

test "the memcopy shape is supported" {
    try std.testing.expect(memcopy.unsupported() == null);
}

test "DMCRAL of zero is a full count, not an empty one" {
    try std.testing.expectEqual(@as(u32, 16), xfer.latchedCount(16));
    try std.testing.expectEqual(xfer.count.wrap, xfer.latchedCount(0));
}

test "DMCRAH is the block size and lives in the high half" {
    try std.testing.expectEqual(@as(u32, 8), xfer.blockSize(8 << xfer.count.high_shift | 4));
    try std.testing.expectEqual(xfer.count.wrap, xfer.blockSize(4));
}

test "a channel armed without DMCRB still transfers one block" {
    try std.testing.expectEqual(@as(u32, 1), xfer.latchedBlocks(0));
    try std.testing.expectEqual(@as(u32, 3), xfer.latchedBlocks(3));
}

test "a running count goes back into DMCRA without touching the block size" {
    const dmcra: u32 = 8 << xfer.count.high_shift | 64;
    try std.testing.expectEqual(
        @as(u32, 8 << xfer.count.high_shift | 7),
        xfer.withCount(dmcra, 7),
    );
}

test "walking an address takes a signed step and wraps like the register" {
    try std.testing.expectEqual(@as(u32, 0x2000_0004), xfer.walk(0x2000_0000, 4));
    try std.testing.expectEqual(@as(u32, 0x1FFF_FFFC), xfer.walk(0x2000_0000, -4));
    try std.testing.expectEqual(@as(u32, 0), xfer.walk(0xFFFF_FFFF, 1));
}
