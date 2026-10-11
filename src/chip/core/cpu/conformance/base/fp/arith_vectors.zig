//! Conformance vectors for the decode group `fp_arith` (RA8EMU-278): the
//! FPv5 three-register instructions (T1) VMLA, VMLS, VNMLA, VNMLS, VMUL,
//! VNMUL, VADD, VSUB, VDIV, VFMA, VFMS, VFNMA and VFNMS in half, single
//! and double precision. Expected values are worked from the Arm ARM
//! (DDI0553): VMLA family rounds the product and then the sum (d + n*m,
//! d - n*m, -d - n*m, -d + n*m), the VFMA family rounds once; division by
//! zero raises DZC, 0/0, inf - inf and 0 * inf give the default NaN with
//! IOC, overflow gives inf with OFC and IXC, a tiny inexact result raises
//! UFC and IXC (tininess before rounding), a quiet NaN operand propagates,
//! a signalling one is quieted with IOC, DN forces the default NaN, FZ
//! flushes a denormal input with IDC, and RMode RZ truncates. Singles are
//! Vx:X, doubles X:Vx, halves read S[x]<15:0> and write Zeros(16):result.
//! D16 and up, VDIV with op set, o:oo = 111, hw2[4] set and the 16-bit
//! space are left unclaimed.
const vector = @import("../../vector.zig");

pub const fpscr_reset: u32 = 0x0004_0000;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// The accumulator / destination, and the two operands.
    d: u64 = 0,
    n: u64 = 0,
    m: u64 = 0,
    d_reg: u5 = 0,
    n_reg: u5 = 1,
    m_reg: u5 = 2,
    double: bool = false,
    fpscr: u32 = fpscr_reset,
};

/// Whether the group claims the encoding, the destination and FPSCR after.
pub const Out = struct {
    claimed: bool = true,
    dst: u64,
    fpscr: u32 = fpscr_reset,
};

const V = vector.Vector(In, Out);
const group = "fp_arith";
pub const none: Out = .{ .claimed = false, .dst = 0, .fpscr = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

fn raised(bits: u32) u32 {
    return fpscr_reset | bits;
}
const ioc: u32 = 1 << 0;
const dzc: u32 = 1 << 1;
const ofc: u32 = 1 << 2;
const ufc: u32 = 1 << 3;
const ixc: u32 = 1 << 4;
const idc: u32 = 1 << 7;

/// S0 = d, S1 = n, S2 = m in the single forms; hw2 op clear / set.
const op0: u16 = 0x0A81;
const op1: u16 = 0x0AC1;
const one: u64 = 0x3F80_0000;
const two: u64 = 0x4000_0000;
const three: u64 = 0x4040_0000;

fn ops(name: []const u8, hw1: u16, hw2: u16, expect: u64) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2, .d = one, .n = two, .m = three }, .{ .dst = expect });
}

pub const all = operations ++ exceptions ++ fused ++ wide ++ unclaimed;

const operations = [_]V{
    ops("vmla.f32 1 + 2*3", 0xEE00, op0, 0x40E0_0000),
    ops("vmls.f32 1 - 2*3", 0xEE00, op1, 0xC0A0_0000),
    ops("vnmla.f32 -1 - 2*3", 0xEE10, op1, 0xC0E0_0000),
    ops("vnmls.f32 -1 + 2*3", 0xEE10, op0, 0x40A0_0000),
    ops("vmul.f32 2*3", 0xEE20, op0, 0x40C0_0000),
    ops("vnmul.f32 -(2*3)", 0xEE20, op1, 0xC0C0_0000),
    ops("vadd.f32 2 + 3", 0xEE30, op0, 0x40A0_0000),
    ops("vsub.f32 2 - 3", 0xEE30, op1, 0xBF80_0000),
    ops("vfma.f32 1 + 2*3", 0xEEA0, op0, 0x40E0_0000),
    ops("vfms.f32 1 - 2*3", 0xEEA0, op1, 0xC0A0_0000),
    ops("vfnma.f32 -1 - 2*3", 0xEE90, op1, 0xC0E0_0000),
    ops("vfnms.f32 -1 + 2*3", 0xEE90, op0, 0x40A0_0000),
    vec("vdiv.f32 2/3 rounds and raises ixc", .{ .hw1 = 0xEE80, .hw2 = op0, .n = two, .m = three }, .{ .dst = 0x3F2A_AAAB, .fpscr = raised(ixc) }),
    vec("vdiv.f32 2/3 in rz truncates", .{ .hw1 = 0xEE80, .hw2 = op0, .n = two, .m = three, .fpscr = 0x00C4_0000 }, .{ .dst = 0x3F2A_AAAA, .fpscr = 0x00C4_0000 | ixc }),
    vec("vadd.f32 s3, s5, s31 decodes vx:x", .{ .hw1 = 0xEE72, .hw2 = 0x1AAF, .d_reg = 3, .n_reg = 5, .m_reg = 31, .n = two, .m = three }, .{ .dst = 0x40A0_0000 }),
};

const exceptions = [_]V{
    vec("vdiv.f32 1/0 is +inf with dzc", .{ .hw1 = 0xEE80, .hw2 = op0, .n = one, .m = 0 }, .{ .dst = 0x7F80_0000, .fpscr = raised(dzc) }),
    vec("vdiv.f32 0/0 is the default nan with ioc", .{ .hw1 = 0xEE80, .hw2 = op0, .n = 0, .m = 0 }, .{ .dst = 0x7FC0_0000, .fpscr = raised(ioc) }),
    vec("vadd.f32 inf + -inf is the default nan with ioc", .{ .hw1 = 0xEE30, .hw2 = op0, .n = 0x7F80_0000, .m = 0xFF80_0000 }, .{ .dst = 0x7FC0_0000, .fpscr = raised(ioc) }),
    vec("vmul.f32 0 * inf is the default nan with ioc", .{ .hw1 = 0xEE20, .hw2 = op0, .n = 0, .m = 0x7F80_0000 }, .{ .dst = 0x7FC0_0000, .fpscr = raised(ioc) }),
    vec("vadd.f32 max + max overflows", .{ .hw1 = 0xEE30, .hw2 = op0, .n = 0x7F7F_FFFF, .m = 0x7F7F_FFFF }, .{ .dst = 0x7F80_0000, .fpscr = raised(ofc | ixc) }),
    vec("vmul.f32 tiny inexact raises ufc", .{ .hw1 = 0xEE20, .hw2 = op0, .n = 0x0080_0001, .m = 0x3F00_0000 }, .{ .dst = 0x0040_0000, .fpscr = raised(ufc | ixc) }),
    vec("vadd.f32 propagates a quiet nan", .{ .hw1 = 0xEE30, .hw2 = op0, .n = 0x7FC0_1234, .m = one }, .{ .dst = 0x7FC0_1234 }),
    vec("vadd.f32 quiets a signalling nan", .{ .hw1 = 0xEE30, .hw2 = op0, .n = one, .m = 0x7F80_0001 }, .{ .dst = 0x7FC0_0001, .fpscr = raised(ioc) }),
    vec("vadd.f32 with dn gives the default nan", .{ .hw1 = 0xEE30, .hw2 = op0, .n = 0x7FC0_1234, .m = one, .fpscr = 0x0204_0000 }, .{ .dst = 0x7FC0_0000, .fpscr = 0x0204_0000 }),
    vec("vadd.f32 with fz flushes a denormal input", .{ .hw1 = 0xEE30, .hw2 = op0, .n = 0x0000_0001, .m = 0, .fpscr = 0x0104_0000 }, .{ .dst = 0, .fpscr = 0x0104_0000 | idc }),
};

/// d = -1, n = 1 + 2^-23, m = 1 - 2^-24: the product rounds to 1.0 for
/// VMLA, so the sum is +0 and inexact; VFMA keeps it exact.
const fused = [_]V{
    vec("vmla.f32 rounds the product first", .{ .hw1 = 0xEE00, .hw2 = op0, .d = 0xBF80_0000, .n = 0x3F80_0001, .m = 0x3F7F_FFFF }, .{ .dst = 0, .fpscr = raised(ixc) }),
    vec("vfma.f32 rounds once", .{ .hw1 = 0xEEA0, .hw2 = op0, .d = 0xBF80_0000, .n = 0x3F80_0001, .m = 0x3F7F_FFFF }, .{ .dst = 0x337F_FFFE }),
};

const wide = [_]V{
    vec("vadd.f64 d0, d1, d2", .{ .hw1 = 0xEE31, .hw2 = 0x0B02, .double = true, .n = 0x3FF8_0000_0000_0000, .m = 0x4002_0000_0000_0000 }, .{ .dst = 0x400E_0000_0000_0000 }),
    vec("vdiv.f64 1/3 rounds and raises ixc", .{ .hw1 = 0xEE81, .hw2 = 0x0B02, .double = true, .n = 0x3FF0_0000_0000_0000, .m = 0x4008_0000_0000_0000 }, .{ .dst = 0x3FD5_5555_5555_5555, .fpscr = raised(ixc) }),
    vec("vfma.f64 1 + 2*3", .{ .hw1 = 0xEEA1, .hw2 = 0x0B02, .double = true, .d = 0x3FF0_0000_0000_0000, .n = 0x4000_0000_0000_0000, .m = 0x4008_0000_0000_0000 }, .{ .dst = 0x401C_0000_0000_0000 }),
    vec("vadd.f16 1 + 2", .{ .hw1 = 0xEE30, .hw2 = 0x0981, .n = 0x3C00, .m = 0x4000 }, .{ .dst = 0x4200 }),
    vec("vmul.f16 reads only the low halves", .{ .hw1 = 0xEE20, .hw2 = 0x0981, .n = 0xFFFF_4000, .m = 0xFFFF_4200 }, .{ .dst = 0x4600 }),
    vec("vfma.f16 1 + 2*3", .{ .hw1 = 0xEEA0, .hw2 = 0x0981, .d = 0x3C00, .n = 0x4000, .m = 0x4200 }, .{ .dst = 0x4700 }),
};

const unclaimed = [_]V{
    bad("vadd.f64 d16, d1, d2 is unclaimed", 0xEE71, 0x0B02),
    bad("vadd.f64 d0, d17, d2 is unclaimed", 0xEE31, 0x0B82),
    bad("vadd.f64 d0, d1, d18 is unclaimed", 0xEE31, 0x0B22),
    bad("vdiv with op set is unclaimed", 0xEE80, op1),
    bad("o:oo = 111 is not this group", 0xEEB0, op0),
    bad("hw2[4] set is unclaimed", 0xEE30, 0x0A91),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEE30, .hw2 = op0, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
