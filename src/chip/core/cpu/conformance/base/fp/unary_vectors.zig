//! Conformance vectors for the decode group `fp_unary` (RA8EMU-278): FPv5
//! VMOV (immediate), VMOV (register), VABS, VNEG and VSQRT (T1) in half,
//! single and double precision. Expected values are worked from the Arm
//! ARM (DDI0553): VFPExpandImm builds sign a, exponent NOT(b):b..b:cd and
//! fraction efgh:0..0; VMOV, VABS and VNEG move bits and never touch FPSCR
//! (a signalling NaN passes through unquieted); VSQRT rounds to nearest,
//! raises IXC when inexact, gives the default NaN with IOC for a negative
//! operand, quiets a signalling NaN with IOC, and keeps -0 and +inf.
//! Half-precision results are Zeros(16):result. Single registers are Vx:X,
//! doubles X:Vx. VMOV (register) in half precision, D16 and up, opc2
//! values outside 0000/0001 or the immediate, hw2[7:4] with bit 6 clear
//! but not 0000, hw2[4] set and the 16-bit space are left unclaimed.
const vector = @import("../../vector.zig");

/// The destination's value before the instruction, in either width.
pub const dst_reset: u64 = 0xFFFF_FFFF_FFFF_FFFF;
pub const fpscr_reset: u32 = 0x0004_0000;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// Operand written to S/D `src_reg`; the destination is `dst_reg`.
    src: u64 = 0,
    src_reg: u5 = 1,
    dst_reg: u5 = 0,
    double: bool = false,
};

/// Whether the group claims the encoding, the destination register and
/// FPSCR after.
pub const Out = struct {
    claimed: bool = true,
    dst: u64,
    fpscr: u32 = fpscr_reset,
};

const V = vector.Vector(In, Out);
const group = "fp_unary";
pub const none: Out = .{ .claimed = false, .dst = 0, .fpscr = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

const ioc: u32 = fpscr_reset | 1;
const ixc: u32 = fpscr_reset | 1 << 4;

pub const all = immediate ++ single ++ sqrt ++ double ++ half ++ unclaimed;

const immediate = [_]V{
    vec("vmov.f32 s0, #1.0", .{ .hw1 = 0xEEB7, .hw2 = 0x0A00 }, .{ .dst = 0x3F80_0000 }),
    vec("vmov.f32 s0, #2.0 (imm8 0)", .{ .hw1 = 0xEEB0, .hw2 = 0x0A00 }, .{ .dst = 0x4000_0000 }),
    vec("vmov.f32 s0, #-2.0", .{ .hw1 = 0xEEB8, .hw2 = 0x0A00 }, .{ .dst = 0xC000_0000 }),
    vec("vmov.f32 s0, #1.9375", .{ .hw1 = 0xEEB7, .hw2 = 0x0A0F }, .{ .dst = 0x3FF8_0000 }),
    vec("vmov.f32 s0, #0.5", .{ .hw1 = 0xEEB6, .hw2 = 0x0A00 }, .{ .dst = 0x3F00_0000 }),
    vec("vmov.f32 s0, #4.0", .{ .hw1 = 0xEEB1, .hw2 = 0x0A00 }, .{ .dst = 0x4080_0000 }),
    vec("vmov.f64 d0, #1.0", .{ .hw1 = 0xEEB7, .hw2 = 0x0B00, .double = true }, .{ .dst = 0x3FF0_0000_0000_0000 }),
    vec("vmov.f64 d0, #-2.0", .{ .hw1 = 0xEEB8, .hw2 = 0x0B00, .double = true }, .{ .dst = 0xC000_0000_0000_0000 }),
    vec("vmov.f16 s0, #1.0 zeroes the top half", .{ .hw1 = 0xEEB7, .hw2 = 0x0900 }, .{ .dst = 0x3C00 }),
};

const single = [_]V{
    vec("vmov.f32 s0, s1", .{ .hw1 = 0xEEB0, .hw2 = 0x0A60, .src = 0x1234_5678 }, .{ .dst = 0x1234_5678 }),
    vec("vmov.f32 s1, s0 takes D as the low bit", .{ .hw1 = 0xEEF0, .hw2 = 0x0A40, .src = 0x0BAD_F00D, .src_reg = 0, .dst_reg = 1 }, .{ .dst = 0x0BAD_F00D }),
    vec("vmov.f32 s31, s30", .{ .hw1 = 0xEEF0, .hw2 = 0xFA4F, .src = 0x4242_4242, .src_reg = 30, .dst_reg = 31 }, .{ .dst = 0x4242_4242 }),
    vec("vmov.f32 keeps a signalling nan", .{ .hw1 = 0xEEB0, .hw2 = 0x0A60, .src = 0x7F80_0001 }, .{ .dst = 0x7F80_0001 }),
    vec("vabs.f32 of -1.5", .{ .hw1 = 0xEEB0, .hw2 = 0x0AE0, .src = 0xBFC0_0000 }, .{ .dst = 0x3FC0_0000 }),
    vec("vabs.f32 of -0", .{ .hw1 = 0xEEB0, .hw2 = 0x0AE0, .src = 0x8000_0000 }, .{ .dst = 0 }),
    vec("vabs.f32 of a negative nan moves bits", .{ .hw1 = 0xEEB0, .hw2 = 0x0AE0, .src = 0xFFC0_0000 }, .{ .dst = 0x7FC0_0000 }),
    vec("vneg.f32 of 1.0", .{ .hw1 = 0xEEB1, .hw2 = 0x0A60, .src = 0x3F80_0000 }, .{ .dst = 0xBF80_0000 }),
    vec("vneg.f32 of +0", .{ .hw1 = 0xEEB1, .hw2 = 0x0A60, .src = 0 }, .{ .dst = 0x8000_0000 }),
    vec("vneg.f32 of a signalling nan raises nothing", .{ .hw1 = 0xEEB1, .hw2 = 0x0A60, .src = 0x7F80_0001 }, .{ .dst = 0xFF80_0001 }),
};

const sqrt = [_]V{
    vec("vsqrt.f32 of 4 is exact", .{ .hw1 = 0xEEB1, .hw2 = 0x0AE0, .src = 0x4080_0000 }, .{ .dst = 0x4000_0000 }),
    vec("vsqrt.f32 of 2 rounds and raises ixc", .{ .hw1 = 0xEEB1, .hw2 = 0x0AE0, .src = 0x4000_0000 }, .{ .dst = 0x3FB5_04F3, .fpscr = ixc }),
    vec("vsqrt.f32 of -1 is the default nan", .{ .hw1 = 0xEEB1, .hw2 = 0x0AE0, .src = 0xBF80_0000 }, .{ .dst = 0x7FC0_0000, .fpscr = ioc }),
    vec("vsqrt.f32 of -0 is -0", .{ .hw1 = 0xEEB1, .hw2 = 0x0AE0, .src = 0x8000_0000 }, .{ .dst = 0x8000_0000 }),
    vec("vsqrt.f32 of +inf is +inf", .{ .hw1 = 0xEEB1, .hw2 = 0x0AE0, .src = 0x7F80_0000 }, .{ .dst = 0x7F80_0000 }),
    vec("vsqrt.f32 quiets a signalling nan", .{ .hw1 = 0xEEB1, .hw2 = 0x0AE0, .src = 0x7F80_0001 }, .{ .dst = 0x7FC0_0001, .fpscr = ioc }),
    vec("vsqrt.f32 passes a quiet nan", .{ .hw1 = 0xEEB1, .hw2 = 0x0AE0, .src = 0x7FC0_1234 }, .{ .dst = 0x7FC0_1234 }),
};

const double = [_]V{
    vec("vmov.f64 d0, d1", .{ .hw1 = 0xEEB0, .hw2 = 0x0B41, .double = true, .src = 0x0123_4567_89AB_CDEF }, .{ .dst = 0x0123_4567_89AB_CDEF }),
    vec("vabs.f64 of -2.0", .{ .hw1 = 0xEEB0, .hw2 = 0x0BC1, .double = true, .src = 0xC000_0000_0000_0000 }, .{ .dst = 0x4000_0000_0000_0000 }),
    vec("vneg.f64 of 1.0", .{ .hw1 = 0xEEB1, .hw2 = 0x0B41, .double = true, .src = 0x3FF0_0000_0000_0000 }, .{ .dst = 0xBFF0_0000_0000_0000 }),
    vec("vsqrt.f64 of 4.0", .{ .hw1 = 0xEEB1, .hw2 = 0x0BC1, .double = true, .src = 0x4010_0000_0000_0000 }, .{ .dst = 0x4000_0000_0000_0000 }),
    vec("vsqrt.f64 of 2.0 rounds and raises ixc", .{ .hw1 = 0xEEB1, .hw2 = 0x0BC1, .double = true, .src = 0x4000_0000_0000_0000 }, .{ .dst = 0x3FF6_A09E_667F_3BCD, .fpscr = ixc }),
};

const half = [_]V{
    vec("vabs.f16 of -1.0 zeroes the top half", .{ .hw1 = 0xEEB0, .hw2 = 0x09E0, .src = 0xBC00 }, .{ .dst = 0x3C00 }),
    vec("vneg.f16 of 2.0", .{ .hw1 = 0xEEB1, .hw2 = 0x0960, .src = 0x4000 }, .{ .dst = 0xC000 }),
    vec("vsqrt.f16 of 4.0", .{ .hw1 = 0xEEB1, .hw2 = 0x09E0, .src = 0x4400 }, .{ .dst = 0x4000 }),
    vec("vabs.f16 reads only the low half", .{ .hw1 = 0xEEB0, .hw2 = 0x09E0, .src = 0xFFFF_BC00 }, .{ .dst = 0x3C00 }),
};

const unclaimed = [_]V{
    bad("vmov.f16 register has no half form", 0xEEB0, 0x0960),
    bad("vmov.f64 d16, d1 is unclaimed", 0xEEF0, 0x0B41),
    bad("vabs.f64 d0, d17 is unclaimed", 0xEEB0, 0x0BE1),
    bad("vmov.f64 d16, #1.0 is unclaimed", 0xEEF7, 0x0B00),
    bad("opc2 0010 is not this group", 0xEEB2, 0x0A60),
    bad("opc2 1000 is not this group", 0xEEB8, 0x0A60),
    bad("hw2[7:4] = 0010 is unclaimed", 0xEEB0, 0x0A20),
    bad("hw2[4] set is unclaimed", 0xEEB0, 0x0A10),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEEB0, .hw2 = 0x0A60, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
