const std = @import("std");
const ra8 = @import("ra8");
const fpscr = ra8.chip.core.cpu.fpu.fpscr;
const Fpscr = fpscr.Fpscr;

test "each field sits on the bit the Arm ARM gives it" {
    try std.testing.expectEqual(@as(u32, 1 << 0), (Fpscr{ .ltpsize = 0, .ioc = 1 }).bits());
    try std.testing.expectEqual(@as(u32, 1 << 4), (Fpscr{ .ltpsize = 0, .ixc = 1 }).bits());
    try std.testing.expectEqual(@as(u32, 1 << 7), (Fpscr{ .ltpsize = 0, .idc = 1 }).bits());
    try std.testing.expectEqual(@as(u32, 1 << 19), (Fpscr{ .ltpsize = 0, .fz16 = 1 }).bits());
    try std.testing.expectEqual(@as(u32, 0b11 << 22), (Fpscr{ .ltpsize = 0, .rmode = .zero }).bits());
    try std.testing.expectEqual(@as(u32, 1 << 24), (Fpscr{ .ltpsize = 0, .fz = 1 }).bits());
    try std.testing.expectEqual(@as(u32, 1 << 25), (Fpscr{ .ltpsize = 0, .dn = 1 }).bits());
    try std.testing.expectEqual(@as(u32, 1 << 26), (Fpscr{ .ltpsize = 0, .ahp = 1 }).bits());
    try std.testing.expectEqual(@as(u32, 1 << 27), (Fpscr{ .ltpsize = 0, .qc = 1 }).bits());
    try std.testing.expectEqual(@as(u32, 1 << 31), (Fpscr{ .ltpsize = 0, .n = 1 }).bits());
}

test "the default value has LTPSIZE 4, no tail predication, and nothing else set" {
    try std.testing.expectEqual(@as(u32, 0x0004_0000), (Fpscr{}).bits());
}

test "a write keeps every implemented bit and drops the reserved ones" {
    const all = Fpscr.fromBits(0xFFFF_FFFF);
    try std.testing.expectEqual(fpscr.mask.writable, all.bits());
    try std.testing.expectEqual(fpscr.RMode.zero, all.rmode);
    try std.testing.expectEqual(@as(u32, 0), Fpscr.fromBits(0x0030_FF60).bits());
}

test "rounding mode reads back from bits 22 and 23" {
    try std.testing.expectEqual(fpscr.RMode.plus_inf, Fpscr.fromBits(0b01 << 22).rmode);
    try std.testing.expectEqual(fpscr.RMode.minus_inf, Fpscr.fromBits(0b10 << 22).rmode);
}

test "flushes picks FZ16 for half precision and FZ otherwise" {
    const half_only: Fpscr = .{ .fz16 = 1 };
    try std.testing.expect(half_only.flushes(16));
    try std.testing.expect(!half_only.flushes(32));
    const single_only: Fpscr = .{ .fz = 1 };
    try std.testing.expect(!single_only.flushes(16));
    try std.testing.expect(single_only.flushes(64));
}
