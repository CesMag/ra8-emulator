//! Conformance vectors for the decode group `fp_directed` (RA8EMU-278):
//! VSEL, VMAXNM/VMINNM, VRINTA/N/P/M, VRINTR/Z/X and VCVTA/N/P/M in half,
//! single and double precision. Expected values are worked from the Arm
//! ARM (DDI0553): VSEL picks Sn when EQ/VS/GE/GT holds on the APSR flags,
//! else Sm; VMAXNM/VMINNM return the number when the other operand is a
//! quiet NaN, quiet a signalling NaN with IOC, and order +0 above -0;
//! VRINTA/N/P/M round to an integral float by the encoded mode without
//! IXC, keeping the sign of zero; VRINTR uses FPSCR.RMode, VRINTZ rounds
//! toward zero, VRINTX raises IXC when inexact; VCVTA/N/P/M round by the
//! encoded mode to S32/U32 with IXC when inexact and saturate with IOC.
//! VSEL with o set, VRINT{A,N,P,M,X} with N set, D16 and up, unused hw1
//! patterns, hw2[4] set and the 16-bit space are left unclaimed.
const vector = @import("../../vector.zig");

pub const fpscr_reset: u32 = 0x0004_0000;
pub const dst_reset: u64 = 0xFFFF_FFFF_FFFF_FFFF;
pub const xpsr_thumb: u32 = 0x0100_0000;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// Sn/Dn and Sm/Dm; the destination is preset to all ones.
    n: u64 = 0,
    m: u64 = 0,
    d_reg: u5 = 0,
    n_reg: u5 = 1,
    m_reg: u5 = 2,
    /// Width of the sources, and of the destination.
    double: bool = false,
    dst_wide: bool = false,
    xpsr: u32 = xpsr_thumb,
    fpscr: u32 = fpscr_reset,
};

/// Whether the group claims the encoding, the destination and FPSCR after.
pub const Out = struct {
    claimed: bool = true,
    dst: u64,
    fpscr: u32 = fpscr_reset,
};

const V = vector.Vector(In, Out);
const group = "fp_directed";
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
const ixc: u32 = 1 << 4;

const z_flag: u32 = 1 << 30;
const n_flag: u32 = 1 << 31;
const v_flag: u32 = 1 << 28;

/// Sd = S0, Sn = S1, Sm = S2. `two_ops` has o clear (VSEL, VMAXNM),
/// `min_op` has o set (VMINNM); `one_op` is the Sm-only form with N clear
/// and `one_op_n` with N set.
const two_ops: u16 = 0x0A81;
const min_op: u16 = 0x0AC1;
const one_op: u16 = 0x0A41;
const one_op_n: u16 = 0x0AC1;
const one: u64 = 0x3F80_0000;
const two: u64 = 0x4000_0000;

fn pick(name: []const u8, hw1: u16, flags: u32, take_n: bool) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = two_ops, .n = one, .m = two, .xpsr = xpsr_thumb | flags }, .{ .dst = if (take_n) one else two });
}

fn round(name: []const u8, hw1: u16, hw2: u16, value: u64, expect: u64, fpscr: u32) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2, .m = value }, .{ .dst = expect, .fpscr = fpscr });
}

pub const all = select ++ maxmin ++ rint ++ cvt ++ wide ++ unclaimed;

const select = [_]V{
    pick("vseleq with z set takes sn", 0xFE00, z_flag, true),
    pick("vseleq with z clear takes sm", 0xFE00, 0, false),
    pick("vselvs with v set takes sn", 0xFE10, v_flag, true),
    pick("vselvs with v clear takes sm", 0xFE10, 0, false),
    pick("vselge with n == v takes sn", 0xFE20, n_flag | v_flag, true),
    pick("vselge with n != v takes sm", 0xFE20, n_flag, false),
    pick("vselgt with z clear and n == v takes sn", 0xFE30, 0, true),
    pick("vselgt with z set takes sm", 0xFE30, z_flag, false),
};

const maxmin = [_]V{
    vec("vmaxnm.f32 1, 2", .{ .hw1 = 0xFE80, .hw2 = two_ops, .n = one, .m = two }, .{ .dst = two }),
    vec("vminnm.f32 1, 2", .{ .hw1 = 0xFE80, .hw2 = min_op, .n = one, .m = two }, .{ .dst = one }),
    vec("vmaxnm.f32 quiet nan returns the number", .{ .hw1 = 0xFE80, .hw2 = two_ops, .n = 0x7FC0_0000, .m = one }, .{ .dst = one }),
    vec("vminnm.f32 quiet nan returns the number", .{ .hw1 = 0xFE80, .hw2 = min_op, .n = one, .m = 0x7FC0_0000 }, .{ .dst = one }),
    vec("vmaxnm.f32 signalling nan is quieted", .{ .hw1 = 0xFE80, .hw2 = two_ops, .n = 0x7F80_0001, .m = one }, .{ .dst = 0x7FC0_0001, .fpscr = raised(ioc) }),
    vec("vmaxnm.f32 +0, -0 is +0", .{ .hw1 = 0xFE80, .hw2 = two_ops, .n = 0x8000_0000, .m = 0 }, .{ .dst = 0 }),
    vec("vminnm.f32 +0, -0 is -0", .{ .hw1 = 0xFE80, .hw2 = min_op, .n = 0, .m = 0x8000_0000 }, .{ .dst = 0x8000_0000 }),
};

const rint = [_]V{
    round("vrinta.f32 2.5 ties away", 0xFEB8, one_op, 0x4020_0000, 0x4040_0000, fpscr_reset),
    round("vrinta.f32 -2.5 ties away", 0xFEB8, one_op, 0xC020_0000, 0xC040_0000, fpscr_reset),
    round("vrinta.f32 -0.3 keeps -0", 0xFEB8, one_op, 0xBE99_999A, 0x8000_0000, fpscr_reset),
    round("vrintn.f32 2.5 ties to even", 0xFEB9, one_op, 0x4020_0000, 0x4000_0000, fpscr_reset),
    round("vrintp.f32 2.1 rounds up", 0xFEBA, one_op, 0x4006_6666, 0x4040_0000, fpscr_reset),
    round("vrintm.f32 -2.1 rounds down", 0xFEBB, one_op, 0xC006_6666, 0xC040_0000, fpscr_reset),
    round("vrintz.f32 -2.7 toward zero", 0xEEB6, one_op_n, 0xC02C_CCCD, 0xC000_0000, fpscr_reset),
    round("vrintr.f32 3.5 in rn", 0xEEB6, one_op, 0x4060_0000, 0x4080_0000, fpscr_reset),
    vec("vrintr.f32 3.5 in rz", .{ .hw1 = 0xEEB6, .hw2 = one_op, .m = 0x4060_0000, .fpscr = 0x00C4_0000 }, .{ .dst = 0x4040_0000, .fpscr = 0x00C4_0000 }),
    round("vrintx.f32 2.5 raises ixc", 0xEEB7, one_op, 0x4020_0000, 0x4000_0000, raised(ixc)),
    round("vrintx.f32 3.0 is exact", 0xEEB7, one_op, 0x4040_0000, 0x4040_0000, fpscr_reset),
    round("vrintn.f32 quiets a signalling nan", 0xFEB9, one_op, 0x7F80_0001, 0x7FC0_0001, raised(ioc)),
};

const cvt = [_]V{
    round("vcvta.s32.f32 -2.5 ties away", 0xFEBC, one_op_n, 0xC020_0000, 0xFFFF_FFFD, raised(ixc)),
    round("vcvtn.s32.f32 2.5 ties to even", 0xFEBD, one_op_n, 0x4020_0000, 2, raised(ixc)),
    round("vcvtp.u32.f32 2.1 rounds up", 0xFEBE, one_op, 0x4006_6666, 3, raised(ixc)),
    round("vcvtm.s32.f32 -2.1 rounds down", 0xFEBF, one_op_n, 0xC006_6666, 0xFFFF_FFFD, raised(ixc)),
    round("vcvtm.u32.f32 -0.5 saturates to zero", 0xFEBF, one_op, 0xBF00_0000, 0, raised(ioc)),
    round("vcvta.s32.f32 3.0 is exact", 0xFEBC, one_op_n, 0x4040_0000, 3, fpscr_reset),
};

const wide = [_]V{
    vec("vselge.f64 d0, d1, d2", .{ .hw1 = 0xFE21, .hw2 = 0x0B02, .double = true, .dst_wide = true, .n = 0x3FF0_0000_0000_0000, .m = 0x4000_0000_0000_0000 }, .{ .dst = 0x3FF0_0000_0000_0000 }),
    vec("vmaxnm.f64 d0, d1, d2", .{ .hw1 = 0xFE81, .hw2 = 0x0B02, .double = true, .dst_wide = true, .n = 0x3FF0_0000_0000_0000, .m = 0x4000_0000_0000_0000 }, .{ .dst = 0x4000_0000_0000_0000 }),
    vec("vrintn.f64 d0, d2 ties to even", .{ .hw1 = 0xFEB9, .hw2 = 0x0B42, .double = true, .dst_wide = true, .m = 0x4004_0000_0000_0000 }, .{ .dst = 0x4000_0000_0000_0000 }),
    vec("vcvta.s32.f64 s0, d2", .{ .hw1 = 0xFEBC, .hw2 = 0x0BC2, .double = true, .m = 0xC004_0000_0000_0000 }, .{ .dst = 0xFFFF_FFFD, .fpscr = raised(ixc) }),
    vec("vrinta.f16 2.5 ties away", .{ .hw1 = 0xFEB8, .hw2 = 0x0941, .m = 0x4100 }, .{ .dst = 0x4200 }),
    vec("vseleq.f16 with z set", .{ .hw1 = 0xFE00, .hw2 = 0x0981, .n = 0x3C00, .m = 0x4000, .xpsr = xpsr_thumb | z_flag }, .{ .dst = 0x3C00 }),
    vec("vcvta.s32.f16 writes a full word", .{ .hw1 = 0xFEBC, .hw2 = 0x09C1, .m = 0xC100 }, .{ .dst = 0xFFFF_FFFD, .fpscr = raised(ixc) }),
};

const unclaimed = [_]V{
    bad("vsel with o set is unclaimed", 0xFE00, min_op),
    bad("vrinta with n set is unclaimed", 0xFEB8, one_op_n),
    bad("vrintx with n set is unclaimed", 0xEEB7, one_op_n),
    bad("vmaxnm.f64 d16 is unclaimed", 0xFEC1, 0x0B02),
    bad("vsel.f64 d0, d17, d2 is unclaimed", 0xFE01, 0x0B82),
    bad("hw1 0xFE90 is unclaimed", 0xFE90, one_op_n),
    bad("hw2[4] set is unclaimed", 0xFE80, 0x0A91),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xFE80, .hw2 = two_ops, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
