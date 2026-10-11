//! Conformance vectors for the decode group `fp.convert` (RA8EMU-278): the
//! FPv5 VCVT family (T1). Expected values are worked from the Arm ARM
//! (DDI0553): single <-> double rounds by FPSCR and moves a signalling
//! NaN's payload to the top, quieted, with IOC; VCVT to S32/U32 truncates
//! and VCVTR uses RMode (ties to even), saturating with IOC on NaN or out
//! of range; S32/U32 to float rounds by RMode; fixed point converts Sd/Dd
//! in place with fbits = width - imm5, results extended to the register;
//! VCVTB/VCVTT read or write the bottom/top half lane, keeping the other
//! lane. opc2 0111 with o clear, D16 and up, imm5 wider than the integer,
//! hw2[6] clear and the 16-bit space are left unclaimed.
const vector = @import("../../vector.zig");

pub const fpscr_reset: u32 = 0x0004_0000;
pub const dst_reset: u64 = 0xFFFF_FFFF_FFFF_FFFF;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// The source, written after the destination is preset; fixed-point
    /// forms convert in place, so their source register is the destination.
    src: u64 = 0,
    src_reg: u5 = 1,
    src_wide: bool = false,
    dst_reg: u5 = 0,
    dst_wide: bool = false,
    fpscr: u32 = fpscr_reset,
};

/// Whether the group claims the encoding, the destination and FPSCR after.
pub const Out = struct {
    claimed: bool = true,
    dst: u64,
    fpscr: u32 = fpscr_reset,
};

const V = vector.Vector(In, Out);
const group = "fp_convert";
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
const ofc: u32 = 1 << 2;
const ixc: u32 = 1 << 4;

pub const all = precision ++ to_int ++ from_int ++ fixed ++ half ++ unclaimed;

const precision = [_]V{
    vec("vcvt.f64.f32 d0, s2", .{ .hw1 = 0xEEB7, .hw2 = 0x0AC1, .src = 0x3F80_0000, .src_reg = 2, .dst_wide = true }, .{ .dst = 0x3FF0_0000_0000_0000 }),
    vec("vcvt.f64.f32 moves a signalling payload up, quieted", .{ .hw1 = 0xEEB7, .hw2 = 0x0AC1, .src = 0x7F80_0001, .src_reg = 2, .dst_wide = true }, .{ .dst = 0x7FF8_0000_2000_0000, .fpscr = raised(ioc) }),
    vec("vcvt.f32.f64 s0, d1 rounds 1/3", .{ .hw1 = 0xEEB7, .hw2 = 0x0BC1, .src = 0x3FD5_5555_5555_5555, .src_wide = true }, .{ .dst = 0x3EAA_AAAB, .fpscr = raised(ixc) }),
    vec("vcvt.f32.f64 overflows to inf", .{ .hw1 = 0xEEB7, .hw2 = 0x0BC1, .src = 0x7E37_E43C_8800_759C, .src_wide = true }, .{ .dst = 0x7F80_0000, .fpscr = raised(ofc | ixc) }),
    vec("vcvt.f32.f64 quiets a signalling nan", .{ .hw1 = 0xEEB7, .hw2 = 0x0BC1, .src = 0x7FF0_0000_0000_0001, .src_wide = true }, .{ .dst = 0x7FC0_0000, .fpscr = raised(ioc) }),
};

const to_int = [_]V{
    vec("vcvt.s32.f32 -2.5 truncates", .{ .hw1 = 0xEEBD, .hw2 = 0x0AE0, .src = 0xC020_0000 }, .{ .dst = 0xFFFF_FFFE, .fpscr = raised(ixc) }),
    vec("vcvtr.s32.f32 2.5 ties to even", .{ .hw1 = 0xEEBD, .hw2 = 0x0A60, .src = 0x4020_0000 }, .{ .dst = 2, .fpscr = raised(ixc) }),
    vec("vcvtr.s32.f32 3.5 ties to even", .{ .hw1 = 0xEEBD, .hw2 = 0x0A60, .src = 0x4060_0000 }, .{ .dst = 4, .fpscr = raised(ixc) }),
    vec("vcvtr.s32.f32 -2.5 in rm", .{ .hw1 = 0xEEBD, .hw2 = 0x0A60, .src = 0xC020_0000, .fpscr = 0x0084_0000 }, .{ .dst = 0xFFFF_FFFD, .fpscr = 0x0084_0000 | ixc }),
    vec("vcvt.s32.f32 2^31 saturates", .{ .hw1 = 0xEEBD, .hw2 = 0x0AE0, .src = 0x4F00_0000 }, .{ .dst = 0x7FFF_FFFF, .fpscr = raised(ioc) }),
    vec("vcvt.s32.f32 nan is zero with ioc", .{ .hw1 = 0xEEBD, .hw2 = 0x0AE0, .src = 0x7FC0_0000 }, .{ .dst = 0, .fpscr = raised(ioc) }),
    vec("vcvt.u32.f32 -1 saturates to zero", .{ .hw1 = 0xEEBC, .hw2 = 0x0AE0, .src = 0xBF80_0000 }, .{ .dst = 0, .fpscr = raised(ioc) }),
    vec("vcvt.u32.f32 2^32 saturates", .{ .hw1 = 0xEEBC, .hw2 = 0x0AE0, .src = 0x4F80_0000 }, .{ .dst = 0xFFFF_FFFF, .fpscr = raised(ioc) }),
    vec("vcvt.u32.f32 3.0 is exact", .{ .hw1 = 0xEEBC, .hw2 = 0x0AE0, .src = 0x4040_0000 }, .{ .dst = 3 }),
    vec("vcvt.s32.f64 s0, d1 -3.75", .{ .hw1 = 0xEEBD, .hw2 = 0x0BC1, .src = 0xC00E_0000_0000_0000, .src_wide = true }, .{ .dst = 0xFFFF_FFFD, .fpscr = raised(ixc) }),
};

const from_int = [_]V{
    vec("vcvt.f32.s32 -1", .{ .hw1 = 0xEEB8, .hw2 = 0x0AE0, .src = 0xFFFF_FFFF }, .{ .dst = 0xBF80_0000 }),
    vec("vcvt.f32.u32 0xffffffff rounds up", .{ .hw1 = 0xEEB8, .hw2 = 0x0A60, .src = 0xFFFF_FFFF }, .{ .dst = 0x4F80_0000, .fpscr = raised(ixc) }),
    vec("vcvt.f32.s32 2^24 + 1 rounds to even", .{ .hw1 = 0xEEB8, .hw2 = 0x0AE0, .src = 0x0100_0001 }, .{ .dst = 0x4B80_0000, .fpscr = raised(ixc) }),
    vec("vcvt.f64.s32 d0, s1 -1", .{ .hw1 = 0xEEB8, .hw2 = 0x0BE0, .src = 0xFFFF_FFFF, .dst_wide = true }, .{ .dst = 0xBFF0_0000_0000_0000 }),
};

const fixed = [_]V{
    vec("vcvt.f32.s32 s0, s0, #16", .{ .hw1 = 0xEEBA, .hw2 = 0x0AC8, .src = 0x0001_8000, .src_reg = 0 }, .{ .dst = 0x3FC0_0000 }),
    vec("vcvt.s32.f32 s0, s0, #16", .{ .hw1 = 0xEEBE, .hw2 = 0x0AC8, .src = 0x3FC0_0000, .src_reg = 0 }, .{ .dst = 0x0001_8000 }),
    vec("vcvt.u16.f32 s0, s0, #8", .{ .hw1 = 0xEEBF, .hw2 = 0x0A44, .src = 0x3FC0_0000, .src_reg = 0 }, .{ .dst = 0x0180 }),
    vec("vcvt.s16.f32 s0, s0, #8 sign-extends", .{ .hw1 = 0xEEBE, .hw2 = 0x0A44, .src = 0xBF80_0000, .src_reg = 0 }, .{ .dst = 0xFFFF_FF00 }),
    vec("vcvt.s16.f32 s0, s0, #8 saturates", .{ .hw1 = 0xEEBE, .hw2 = 0x0A44, .src = 0x4348_0000, .src_reg = 0 }, .{ .dst = 0x7FFF, .fpscr = raised(ioc) }),
    vec("vcvt.f64.s32 d0, d0, #16", .{ .hw1 = 0xEEBA, .hw2 = 0x0BC8, .src = 0x0001_8000, .src_reg = 0, .src_wide = true, .dst_wide = true }, .{ .dst = 0x3FF8_0000_0000_0000 }),
};

const half = [_]V{
    vec("vcvtb.f32.f16 reads the bottom lane", .{ .hw1 = 0xEEB2, .hw2 = 0x0A60, .src = 0x4000_3C00 }, .{ .dst = 0x3F80_0000 }),
    vec("vcvtt.f32.f16 reads the top lane", .{ .hw1 = 0xEEB2, .hw2 = 0x0AE0, .src = 0x4000_3C00 }, .{ .dst = 0x4000_0000 }),
    vec("vcvtb.f16.f32 keeps the top lane", .{ .hw1 = 0xEEB3, .hw2 = 0x0A60, .src = 0x3F80_0000 }, .{ .dst = 0xFFFF_3C00 }),
    vec("vcvtt.f16.f32 keeps the bottom lane", .{ .hw1 = 0xEEB3, .hw2 = 0x0AE0, .src = 0x3F80_0000 }, .{ .dst = 0x3C00_FFFF }),
    vec("vcvtb.f16.f32 overflows to inf", .{ .hw1 = 0xEEB3, .hw2 = 0x0A60, .src = 0x4780_0000 }, .{ .dst = 0xFFFF_7C00, .fpscr = raised(ofc | ixc) }),
    vec("vcvtb.f64.f16 d0, s1", .{ .hw1 = 0xEEB2, .hw2 = 0x0B60, .src = 0x3C00, .dst_wide = true }, .{ .dst = 0x3FF0_0000_0000_0000 }),
    vec("vcvtb.f16.f64 s0, d1", .{ .hw1 = 0xEEB3, .hw2 = 0x0B41, .src = 0x3FF0_0000_0000_0000, .src_wide = true }, .{ .dst = 0xFFFF_3C00 }),
};

const unclaimed = [_]V{
    bad("opc2 0111 with o clear is unclaimed", 0xEEB7, 0x0A41),
    bad("vcvt.f64.f32 d16, s2 is unclaimed", 0xEEF7, 0x0AC1),
    bad("vcvt.f32.f64 s0, d17 is unclaimed", 0xEEB7, 0x0BE1),
    bad("16-bit fixed with imm5 17 is unclaimed", 0xEEBE, 0x0A68),
    bad("opc2 0100 is not this group", 0xEEB4, 0x0A60),
    bad("hw2[6] clear is unclaimed", 0xEEBD, 0x0A81),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEEBD, .hw2 = 0x0AE0, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
