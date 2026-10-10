//! Covers src/chip/core/cpu/mve/tail.zig against the Arm ARM (DDI0553)
//! pseudocode for LE/LETP, VCTP and the tail-predication element mask.
const std = @import("std");
const ra8 = @import("ra8");
const tail = ra8.chip.core.cpu.mve.tail;
const Vpr = ra8.chip.core.cpu.mve.predicate.Vpr;

test "elements per vector for each LTPSIZE" {
    const want = [_]u32{ 16, 8, 4, 2, 1 };
    for (want, 0..) |n, size| try std.testing.expectEqual(n, tail.perVector(@intCast(size)));
}

test "the element mask is full outside a loop and before the last iteration" {
    try std.testing.expectEqual(@as(u16, 0xFFFF), tail.mask(tail.none, 0));
    try std.testing.expectEqual(@as(u16, 0xFFFF), tail.mask(2, 5));
    try std.testing.expectEqual(@as(u16, 0xFFFF), tail.mask(2, 4));
}

test "the last iteration keeps only LR elements" {
    try std.testing.expectEqual(@as(u16, 0x0FFF), tail.mask(2, 3));
    try std.testing.expectEqual(@as(u16, 0x003F), tail.mask(1, 3));
    try std.testing.expectEqual(@as(u16, 0x00FF), tail.mask(3, 1));
    try std.testing.expectEqual(@as(u16, 0x7FFF), tail.mask(0, 15));
    try std.testing.expectEqual(@as(u16, 0), tail.mask(0, 0));
}

test "VCTP's predicate for each element size" {
    try std.testing.expectEqual(@as(u16, 0x001F), tail.vctpMask(0, 5));
    try std.testing.expectEqual(@as(u16, 0x003F), tail.vctpMask(1, 3));
    try std.testing.expectEqual(@as(u16, 0x000F), tail.vctpMask(2, 1));
    try std.testing.expectEqual(@as(u16, 0x00FF), tail.vctpMask(3, 1));
    try std.testing.expectEqual(@as(u16, 0xFFFF), tail.vctpMask(2, 100));
    try std.testing.expectEqual(@as(u16, 0xFFFF), tail.vctpMask(0, 0xFFFF_FFFF));
    try std.testing.expectEqual(@as(u16, 0), tail.vctpMask(1, 0));
}

test "VCTP writes P0 and keeps the VPT masks" {
    const vpr: Vpr = .{ .p0 = 0xAAAA, .mask01 = 0b1000, .mask23 = 0b1000 };
    const out = tail.vctp(vpr, 2, 3, 0xFFFF, 0xFFFF);
    try std.testing.expectEqual(@as(u16, 0x0FFF), out.p0);
    try std.testing.expectEqual(@as(u4, 0b1000), out.mask01);
    try std.testing.expectEqual(@as(u4, 0b1000), out.mask23);
}

test "VCTP ANDs with the mask in force and leaves unexecuted beats alone" {
    const vpr: Vpr = .{ .p0 = 0xAAAA };
    try std.testing.expectEqual(@as(u16, 0x000F), tail.vctp(vpr, 2, 3, 0x000F, 0xFFFF).p0);
    try std.testing.expectEqual(@as(u16, 0x0F0F), tail.vctp(vpr, 2, 3, 0x0F0F, 0xFFFF).p0);
    try std.testing.expectEqual(@as(u16, 0xAAFF), tail.vctp(vpr, 2, 3, 0xFFFF, 0x00FF).p0);
}

test "DLSTP and WLSTP load LR and LTPSIZE; WLSTP skips an empty loop" {
    const d = tail.start(2, 10, false, 99, tail.none);
    try std.testing.expectEqual(tail.Start{ .lr = 10, .ltpsize = 2, .enter = true }, d);
    const w = tail.start(2, 0, true, 99, tail.none);
    try std.testing.expectEqual(tail.Start{ .lr = 99, .ltpsize = tail.none, .enter = false }, w);
    const z = tail.start(1, 0, false, 99, tail.none);
    try std.testing.expectEqual(tail.Start{ .lr = 0, .ltpsize = 1, .enter = true }, z);
}

test "a 10-word loop runs 4, 4, then 2 masked elements and resets LTPSIZE" {
    var lr: u32 = 10;
    var ltpsize: u3 = 2;
    var masks: [3]u16 = undefined;
    var iterations: usize = 0;
    while (true) {
        masks[iterations] = tail.mask(ltpsize, lr);
        iterations += 1;
        const e = tail.end(lr, ltpsize);
        lr = e.lr;
        ltpsize = e.ltpsize;
        if (!e.again) break;
    }
    try std.testing.expectEqual(@as(usize, 3), iterations);
    try std.testing.expectEqualSlices(u16, &.{ 0xFFFF, 0xFFFF, 0x00FF }, &masks);
    try std.testing.expectEqual(@as(u32, 2), lr);
    try std.testing.expectEqual(tail.none, ltpsize);
}

test "LETP on an exact multiple exits with LR at one vector" {
    const e = tail.end(16, 0);
    try std.testing.expectEqual(tail.End{ .lr = 16, .ltpsize = tail.none, .again = false }, e);
}
