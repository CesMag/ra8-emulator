//! Covers src/chip/core/cpu/ops/csel.zig.
//!
//! The second half ports tests/chip/core/csel_test.zig (the old seam's decode
//! and tails) to run each case through the Zig core's decoder and executor
//! instead (RA8EMU-250). The seam's step counter has no core counterpart and
//! stays with the seam.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const csel = ra8.chip.core.cpu.ops.csel;

const n_flag: u32 = 1 << 31;
const z_flag: u32 = 1 << 30;
const c_flag: u32 = 1 << 29;
const v_flag: u32 = 1 << 28;

fn wide(hw1: u16, hw2: u16) ra8.chip.core.cpu.instr.Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

/// Runs the op with r2 = 7, r3 = 40 and the given xPSR; returns r1.
fn run(hw1: u16, hw2: u16, xpsr: u32) !u32 {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[1] = 0xDEAD_BEEF;
    cpu.regs.low[2] = 7;
    cpu.regs.low[3] = 40;
    cpu.regs.xpsr = xpsr;
    const exec = csel.group.decode(wide(hw1, hw2)) orelse return error.NotClaimed;
    try exec(&cpu, wide(hw1, hw2));
    try std.testing.expectEqual(xpsr, cpu.regs.xpsr);
    return cpu.regs.low[1];
}

test "cset r1, eq (csinc r1, zr, zr, ne) from usb_port_init" {
    try std.testing.expectEqual(@as(u32, 1), try run(0xEA5F, 0x911F, z_flag));
    try std.testing.expectEqual(@as(u32, 0), try run(0xEA5F, 0x911F, 0));
}

test "csel r1, r2, r3, eq picks Rn on pass and Rm on fail" {
    try std.testing.expectEqual(@as(u32, 7), try run(0xEA52, 0x8103, z_flag));
    try std.testing.expectEqual(@as(u32, 40), try run(0xEA52, 0x8103, 0));
}

test "csinv and csneg tails on fail" {
    try std.testing.expectEqual(~@as(u32, 40), try run(0xEA52, 0xA103, 0));
    try std.testing.expectEqual(@as(u32, 0) -% 40, try run(0xEA52, 0xB103, 0));
}

test "sp fields, rd = zr, AL and other kinds stay unclaimed" {
    try std.testing.expect(csel.group.decode(wide(0xEA5D, 0x8103)) == null); // Rn = SP
    try std.testing.expect(csel.group.decode(wide(0xEA52, 0x810D)) == null); // Rm = SP
    try std.testing.expect(csel.group.decode(wide(0xEA52, 0x8D03)) == null); // Rd = SP
    try std.testing.expect(csel.group.decode(wide(0xEA52, 0x8F03)) == null); // Rd = ZR
    try std.testing.expect(csel.group.decode(wide(0xEA52, 0x81E3)) == null); // AL
    try std.testing.expect(csel.group.decode(wide(0xEA52, 0x0103)) == null); // not CSEL
}

/// Runs the op on the core with Rn/Rm loaded from the encoding's fields;
/// checks the flags are untouched and returns Rd.
fn runOn(hw1: u16, hw2: u16, xpsr: u32, rn: u32, rm: u32) !u32 {
    var cpu: Cpu = .{ .bus = undefined };
    const n: u4 = @truncate(hw1);
    const m: u4 = @truncate(hw2);
    const d: u4 = @truncate(hw2 >> 8);
    cpu.regs.set(d, 0xDEAD_BEEF);
    if (n != 0xF) cpu.regs.set(n, rn);
    if (m != 0xF) cpu.regs.set(m, rm);
    cpu.regs.xpsr = xpsr;
    const exec = csel.group.decode(wide(hw1, hw2)) orelse return error.NotClaimed;
    try exec(&cpu, wide(hw1, hw2));
    try std.testing.expectEqual(xpsr, cpu.regs.xpsr);
    return cpu.regs.get(d);
}

test "seam port: high registers land in the right fields" {
    // ea5b 8a6c: csel sl, fp, ip, vs
    try std.testing.expectEqual(@as(u32, 11), try runOn(0xEA5B, 0x8A6C, v_flag, 11, 12));
    try std.testing.expectEqual(@as(u32, 12), try runOn(0xEA5B, 0x8A6C, 0, 11, 12));
}

test "seam port: the condition holding takes Rn whichever kind it is" {
    // ea51 8002/9002/a002/b002: csel/csinc/csinv/csneg r0, r1, r2, eq
    for ([_]u16{ 0x8002, 0x9002, 0xA002, 0xB002 }) |hw2| {
        try std.testing.expectEqual(@as(u32, 7), try runOn(0xEA51, hw2, z_flag, 7, 100));
    }
}

test "seam port: the condition failing puts Rm through the tail" {
    try std.testing.expectEqual(@as(u32, 100), try runOn(0xEA51, 0x8002, 0, 7, 100));
    try std.testing.expectEqual(@as(u32, 101), try runOn(0xEA51, 0x9002, 0, 7, 100));
    try std.testing.expectEqual(~@as(u32, 100), try runOn(0xEA51, 0xA002, 0, 7, 100));
    try std.testing.expectEqual(@as(u32, 0) -% 100, try runOn(0xEA51, 0xB002, 0, 7, 100));
}

test "seam port: the tails wrap rather than trap at the edges" {
    try std.testing.expectEqual(@as(u32, 0), try runOn(0xEA51, 0x9002, 0, 0, 0xFFFF_FFFF));
    try std.testing.expectEqual(@as(u32, 0), try runOn(0xEA51, 0xB002, 0, 0, 0));
}

test "seam port: cset r0, eq reads the zero register as zero" {
    // ea5f 901f: csinc r0, zr, zr, ne
    try std.testing.expectEqual(@as(u32, 1), try runOn(0xEA5F, 0x901F, z_flag, 0, 0));
    try std.testing.expectEqual(@as(u32, 0), try runOn(0xEA5F, 0x901F, 0, 0, 0));
}

test "seam port: csetm r2, lt gives an all-ones mask" {
    // ea5f a2af: csinv r2, zr, zr, ge
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), try runOn(0xEA5F, 0xA2AF, n_flag, 0, 0));
    try std.testing.expectEqual(@as(u32, 0), try runOn(0xEA5F, 0xA2AF, 0, 0, 0));
}

test "seam port: every condition code reads the flags the ordinary way" {
    const n = n_flag;
    const z = z_flag;
    const c = c_flag;
    const v = v_flag;
    // { passing xPSR, failing xPSR } for eq ne cs cc mi pl vs vc hi ls ge lt gt le
    const cases = [_][2]u32{
        .{ z, 0 },     .{ 0, z },     .{ c, 0 }, .{ 0, c },     .{ n, 0 },
        .{ 0, n },     .{ v, 0 },     .{ 0, v }, .{ c, c | z }, .{ c | z, c },
        .{ n | v, n }, .{ n, n | v }, .{ 0, z }, .{ z, 0 },
    };
    for (cases, 0..) |pair, cond| {
        // csel r1, r2, r3, <cond>
        const hw2: u16 = 0x8103 | (@as(u16, @intCast(cond)) << 4);
        try std.testing.expectEqual(@as(u32, 7), try runOn(0xEA52, hw2, pair[0], 7, 40));
        try std.testing.expectEqual(@as(u32, 40), try runOn(0xEA52, hw2, pair[1], 7, 40));
    }
}

test "seam port: kinds outside 8..B, condition 0b1111 and a LOB are unclaimed" {
    try std.testing.expect(csel.group.decode(wide(0xEA51, 0x7002)) == null);
    try std.testing.expect(csel.group.decode(wide(0xEA51, 0xC002)) == null);
    try std.testing.expect(csel.group.decode(wide(0xEA51, 0x80F2)) == null);
    try std.testing.expect(csel.group.decode(wide(0xEA50, 0x90E0)) == null); // AL
    try std.testing.expect(csel.group.decode(wide(0xF040, 0xE001)) == null); // wls
}
