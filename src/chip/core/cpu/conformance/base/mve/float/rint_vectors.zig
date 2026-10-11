//! Conformance vectors for the decode group `mve.float.rint` (RA8EMU-278):
//! VRINTN, VRINTX, VRINTA, VRINTZ, VRINTM and VRINTP on F32 and F16 lanes.
//! Expected values are worked from the Arm ARM (DDI0553) pseudocode:
//! FPRoundInt under StandardFPSCRValue (DN and FZ set whatever FPSCR holds,
//! FZ16 left clear here). N and X round to nearest even, A to nearest with
//! ties away, Z toward zero, M toward -inf and P toward +inf; only X raises
//! IXC, and only when the value changed. A NaN gives the default NaN (IOC
//! for a signalling one), zeros and infinities return themselves, an F32
//! denormal flushes to a signed zero with IDC, and a zero result keeps the
//! operand's sign. A lane is computed when any of its bytes is in the mask
//! (VPT, loop tail, EPSR.ECI), its flags count only when its first byte is,
//! and the result merges byte by byte. Qd then Qm is written. Sizes 00 and
//! 11, ops 100 and 110, D or M set, flipped fixed bits and the 16-bit space
//! are left unclaimed.
const vector = @import("../../../vector.zig");

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    qd: u128 = 0,
    qm: u128 = 0,
    vpr: u32 = 0,
    it: u8 = 0,
    lr: u32 = 0,
    fpscr: u32 = 0x0004_0000,
};

pub const Out = struct {
    claimed: bool = true,
    qd: u128,
    fpscr: u32,
    vpr: u32 = 0,
    it: u8 = 0,
};

const V = vector.Vector(In, Out);
const group = "mve_float_rint";
pub const none: Out = .{ .claimed = false, .qd = 0, .fpscr = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = forms ++ predicated ++ unclaimed;

const forms = [_]V{
    vec("vrintn.f32 halves and a negative fraction", .{ .hw1 = 0xFFBA, .hw2 = 0x0444, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0xBE99999A_C0200000_3FC00000_3F000000 }, .{ .qd = 0x80000000_C0000000_40000000_00000000, .fpscr = 0x00040000 }),
    vec("vrintn.f32 fractions near the integer limit and -0", .{ .hw1 = 0xFFBA, .hw2 = 0x0444, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0x80000000_4AFFFFFF_C02CCCCD_402CCCCD }, .{ .qd = 0x80000000_4B000000_C0400000_40400000, .fpscr = 0x00040000 }),
    vec("vrintn.f16 halves, fractions and 1023.5", .{ .hw1 = 0xFFB6, .hw2 = 0x0444, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0x800063FF_C1664166_B4CDC100_3E003800 }, .{ .qd = 0x80006400_C2004200_8000C000_40000000, .fpscr = 0x00040000 }),
    vec("vrintx.f32 halves and a negative fraction", .{ .hw1 = 0xFFBA, .hw2 = 0x04C4, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0xBE99999A_C0200000_3FC00000_3F000000 }, .{ .qd = 0x80000000_C0000000_40000000_00000000, .fpscr = 0x00040010 }),
    vec("vrintx.f32 fractions near the integer limit and -0", .{ .hw1 = 0xFFBA, .hw2 = 0x04C4, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0x80000000_4AFFFFFF_C02CCCCD_402CCCCD }, .{ .qd = 0x80000000_4B000000_C0400000_40400000, .fpscr = 0x00040010 }),
    vec("vrintx.f16 halves, fractions and 1023.5", .{ .hw1 = 0xFFB6, .hw2 = 0x04C4, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0x800063FF_C1664166_B4CDC100_3E003800 }, .{ .qd = 0x80006400_C2004200_8000C000_40000000, .fpscr = 0x00040010 }),
    vec("vrinta.f32 halves and a negative fraction", .{ .hw1 = 0xFFBA, .hw2 = 0x0544, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0xBE99999A_C0200000_3FC00000_3F000000 }, .{ .qd = 0x80000000_C0400000_40000000_3F800000, .fpscr = 0x00040000 }),
    vec("vrinta.f32 fractions near the integer limit and -0", .{ .hw1 = 0xFFBA, .hw2 = 0x0544, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0x80000000_4AFFFFFF_C02CCCCD_402CCCCD }, .{ .qd = 0x80000000_4B000000_C0400000_40400000, .fpscr = 0x00040000 }),
    vec("vrinta.f16 halves, fractions and 1023.5", .{ .hw1 = 0xFFB6, .hw2 = 0x0544, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0x800063FF_C1664166_B4CDC100_3E003800 }, .{ .qd = 0x80006400_C2004200_8000C200_40003C00, .fpscr = 0x00040000 }),
    vec("vrintz.f32 halves and a negative fraction", .{ .hw1 = 0xFFBA, .hw2 = 0x05C4, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0xBE99999A_C0200000_3FC00000_3F000000 }, .{ .qd = 0x80000000_C0000000_3F800000_00000000, .fpscr = 0x00040000 }),
    vec("vrintz.f32 fractions near the integer limit and -0", .{ .hw1 = 0xFFBA, .hw2 = 0x05C4, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0x80000000_4AFFFFFF_C02CCCCD_402CCCCD }, .{ .qd = 0x80000000_4AFFFFFE_C0000000_40000000, .fpscr = 0x00040000 }),
    vec("vrintz.f16 halves, fractions and 1023.5", .{ .hw1 = 0xFFB6, .hw2 = 0x05C4, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0x800063FF_C1664166_B4CDC100_3E003800 }, .{ .qd = 0x800063FE_C0004000_8000C000_3C000000, .fpscr = 0x00040000 }),
    vec("vrintm.f32 halves and a negative fraction", .{ .hw1 = 0xFFBA, .hw2 = 0x06C4, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0xBE99999A_C0200000_3FC00000_3F000000 }, .{ .qd = 0xBF800000_C0400000_3F800000_00000000, .fpscr = 0x00040000 }),
    vec("vrintm.f32 fractions near the integer limit and -0", .{ .hw1 = 0xFFBA, .hw2 = 0x06C4, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0x80000000_4AFFFFFF_C02CCCCD_402CCCCD }, .{ .qd = 0x80000000_4AFFFFFE_C0400000_40000000, .fpscr = 0x00040000 }),
    vec("vrintm.f16 halves, fractions and 1023.5", .{ .hw1 = 0xFFB6, .hw2 = 0x06C4, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0x800063FF_C1664166_B4CDC100_3E003800 }, .{ .qd = 0x800063FE_C2004000_BC00C200_3C000000, .fpscr = 0x00040000 }),
    vec("vrintp.f32 halves and a negative fraction", .{ .hw1 = 0xFFBA, .hw2 = 0x07C4, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0xBE99999A_C0200000_3FC00000_3F000000 }, .{ .qd = 0x80000000_C0000000_40000000_3F800000, .fpscr = 0x00040000 }),
    vec("vrintp.f32 fractions near the integer limit and -0", .{ .hw1 = 0xFFBA, .hw2 = 0x07C4, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0x80000000_4AFFFFFF_C02CCCCD_402CCCCD }, .{ .qd = 0x80000000_4B000000_C0000000_40400000, .fpscr = 0x00040000 }),
    vec("vrintp.f16 halves, fractions and 1023.5", .{ .hw1 = 0xFFB6, .hw2 = 0x07C4, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0x800063FF_C1664166_B4CDC100_3E003800 }, .{ .qd = 0x80006400_C0004200_8000C000_40003C00, .fpscr = 0x00040000 }),
    vec("vrintn.f32 nans, a flushed denormal and -inf", .{ .hw1 = 0xFFBA, .hw2 = 0x0444, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0xFF800000_00000001_7FC00001_7F800001 }, .{ .qd = 0xFF800000_00000000_7FC00000_7FC00000, .fpscr = 0x00040081 }),
    vec("vrintn.f16 nans and kept denormals", .{ .hw1 = 0xFFB6, .hw2 = 0x0444, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0xB8005640_3C007C00_80010001_7E017C01 }, .{ .qd = 0x80005640_3C007C00_80000000_7E007E00, .fpscr = 0x00040001 }),
    vec("vrintx.f32 nans, a flushed denormal and -inf", .{ .hw1 = 0xFFBA, .hw2 = 0x04C4, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0xFF800000_00000001_7FC00001_7F800001 }, .{ .qd = 0xFF800000_00000000_7FC00000_7FC00000, .fpscr = 0x00040081 }),
    vec("vrintx.f16 nans and kept denormals", .{ .hw1 = 0xFFB6, .hw2 = 0x04C4, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0xB8005640_3C007C00_80010001_7E017C01 }, .{ .qd = 0x80005640_3C007C00_80000000_7E007E00, .fpscr = 0x00040011 }),
    vec("vrintp.f32 nans, a flushed denormal and -inf", .{ .hw1 = 0xFFBA, .hw2 = 0x07C4, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0xFF800000_00000001_7FC00001_7F800001 }, .{ .qd = 0xFF800000_00000000_7FC00000_7FC00000, .fpscr = 0x00040081 }),
    vec("vrintp.f16 nans and kept denormals", .{ .hw1 = 0xFFB6, .hw2 = 0x07C4, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0xB8005640_3C007C00_80010001_7E017C01 }, .{ .qd = 0x80005640_3C007C00_80003C00_7E007E00, .fpscr = 0x00040001 }),
    vec("vrintm.f32 a negative flushed denormal, integers and -0.4999", .{ .hw1 = 0xFFBA, .hw2 = 0x06C4, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0xBEFFFFFF_4B000001_3F800000_80400000 }, .{ .qd = 0xBF800000_4B000001_3F800000_80000000, .fpscr = 0x00040080 }),
    vec("vrintx.f32 integers stay exact without ixc", .{ .hw1 = 0xFFBA, .hw2 = 0x04C4, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0x80000000_49800000_C0E00000_3F800000 }, .{ .qd = 0x80000000_49800000_C0E00000_3F800000, .fpscr = 0x00040000 }),
    vec("vrintz.f32 qd = qm", .{ .hw1 = 0xFFBA, .hw2 = 0x85C8, .qm = 0xBE99999A_C0200000_3FC00000_3F000000 }, .{ .qd = 0x80000000_C0000000_3F800000_00000000, .fpscr = 0x00040000 }),
    vec("fpscr rmode and fz clear do not change vrintx", .{ .hw1 = 0xFFBA, .hw2 = 0xE4C2, .qm = 0xBE99999A_C0200000_3FC00000_3F000000, .fpscr = 0x00C40000 }, .{ .qd = 0x80000000_C0000000_40000000_00000000, .fpscr = 0x00C40010 }),
    vec("flags add to the cumulative bits already set", .{ .hw1 = 0xFFBA, .hw2 = 0x04C4, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0xFF800000_00000001_7FC00001_7F800001, .fpscr = 0x00040002 }, .{ .qd = 0xFF800000_00000000_7FC00000_7FC00000, .fpscr = 0x00040083 }),
};

const predicated = [_]V{
    vec("vpt p0 0x0f0e computes lane 0 but drops its flags", .{ .hw1 = 0xFFBA, .hw2 = 0x04C4, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0xBE99999A_C0200000_3FC00000_3F000000, .vpr = 0x00880F0E }, .{ .qd = 0x11111111_C0000000_33333333_00000044, .fpscr = 0x00040010, .vpr = 0x00000F0E }),
    vec("vpt f16 p0 0x3c03", .{ .hw1 = 0xFFB6, .hw2 = 0x0544, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0x800063FF_C1664166_B4CDC100_3E003800, .vpr = 0x00883C03 }, .{ .qd = 0x11116400_C2002222_33333333_44443C00, .fpscr = 0x00040000, .vpr = 0x00003C03 }),
    vec("the loop tail drops lanes 2 and 3", .{ .hw1 = 0xFFBA, .hw2 = 0x04C4, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0xFF800000_00000001_7FC00001_7F800001, .lr = 2, .fpscr = 0x00020000 }, .{ .qd = 0x11111111_22222222_7FC00000_7FC00000, .fpscr = 0x00020001 }),
    vec("the f16 loop tail at ltpsize 1", .{ .hw1 = 0xFFB6, .hw2 = 0x04C4, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0x800063FF_C1664166_B4CDC100_3E003800, .lr = 5, .fpscr = 0x00010000 }, .{ .qd = 0x11111111_22224200_8000C000_40000000, .fpscr = 0x00010010 }),
    vec("eci a0a1 keeps the done lanes and their flags", .{ .hw1 = 0xFFBA, .hw2 = 0x04C4, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0xFF800000_00000001_7FC00001_7F800001, .it = 0x20 }, .{ .qd = 0xFF800000_00000000_33333333_44444444, .fpscr = 0x00040080 }),
};

const unclaimed = [_]V{
    vec("size 00 is unclaimed", .{ .hw1 = 0xFFB2, .hw2 = 0x0444 }, none),
    vec("size 11 is unclaimed", .{ .hw1 = 0xFFBE, .hw2 = 0x0444 }, none),
    vec("op 100 is unclaimed", .{ .hw1 = 0xFFBA, .hw2 = 0x0644 }, none),
    vec("op 110 is unclaimed", .{ .hw1 = 0xFFBA, .hw2 = 0x0744 }, none),
    vec("d set is unclaimed", .{ .hw1 = 0xFFFA, .hw2 = 0x0444 }, none),
    vec("m set is unclaimed", .{ .hw1 = 0xFFBA, .hw2 = 0x0464 }, none),
    vec("hw2[0] set is unclaimed", .{ .hw1 = 0xFFBA, .hw2 = 0x0445 }, none),
    vec("hw2[12:10] other than 001 is unclaimed", .{ .hw1 = 0xFFBA, .hw2 = 0x0C44 }, none),
    vec("hw2[4] set is unclaimed", .{ .hw1 = 0xFFBA, .hw2 = 0x0454 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xFFBA, .hw2 = 0x0444, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
