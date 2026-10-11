//! Conformance vectors for the decode group `mve_float_cvt_fixed`
//! (RA8EMU-278): VCVT between F32 and 32-bit fixed point (1 to 32
//! fraction bits) and between F16 and 16-bit fixed point (1 to 16), both
//! ways, signed and unsigned. Expected values are worked from the Arm ARM
//! (DDI0553) FPToFixed and FixedToFP pseudocode under StandardFPSCRValue.
//! Float to fixed scales by 2^fbits and rounds toward zero; a NaN gives 0
//! with IOC, an infinity or out-of-range value saturates with IOC and no
//! IXC, an inexact result raises IXC, an F32 denormal reads as zero with
//! IDC, and with FZ16 an F16 subnormal reads as zero with no flag. Fixed to
//! float divides by 2^fbits and rounds to nearest even with IXC; an F16
//! result below the normal range is a subnormal, or with FZ16 a signed
//! zero with UFC. A lane runs when any byte is predicated (VPT, loop tail,
//! EPSR.ECI), bytes merge under the mask, and its flags count only when
//! its first byte is. Qd is written before Qm. Q8 and above, the imm6 bits
//! each size fixes, flipped fixed bits and the 16-bit space are unclaimed.
const vector = @import("../../../../vector.zig");

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
const group = "mve_float_cvt_fixed";
pub const none: Out = .{ .claimed = false, .qd = 0, .fpscr = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = to_fixed ++ from_fixed ++ predicated ++ unclaimed;

const to_fixed = [_]V{
    vec("vcvt.s32.f32 #1 fractions", .{ .hw1 = 0xEFBF, .hw2 = 0x0F52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xBF333333_3E99999A_BFA00000_3FC00000 }, .{ .qd = 0xFFFFFFFF_00000000_FFFFFFFE_00000003, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvt.s32.f32 #16 fractions", .{ .hw1 = 0xEFB0, .hw2 = 0x0F52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xBF333333_3E99999A_BFA00000_3FC00000 }, .{ .qd = 0xFFFF4CCD_00004CCC_FFFEC000_00018000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvt.s32.f32 #16 saturation", .{ .hw1 = 0xEFB0, .hw2 = 0x0F52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x40000000_C7000000_47000000_477FFFFD }, .{ .qd = 0x00020000_80000000_7FFFFFFF_7FFFFFFF, .fpscr = 0x00040001, .vpr = 0x00000000 }),
    vec("vcvt.s32.f32 #16 nans, infinities and a flushed denormal", .{ .hw1 = 0xEFB0, .hw2 = 0x0F52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x00000123_FF800000_FF800001_7FC00000 }, .{ .qd = 0x00000000_80000000_00000000_00000000, .fpscr = 0x00040081, .vpr = 0x00000000 }),
    vec("vcvt.s32.f32 #32 fractions", .{ .hw1 = 0xEFA0, .hw2 = 0x0F52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xBF333333_3E99999A_BFA00000_3FC00000 }, .{ .qd = 0x80000000_4CCCCD00_80000000_7FFFFFFF, .fpscr = 0x00040001, .vpr = 0x00000000 }),
    vec("vcvt.s32.f32 #32 saturation", .{ .hw1 = 0xEFA0, .hw2 = 0x0F52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x40000000_C7000000_47000000_477FFFFD }, .{ .qd = 0x7FFFFFFF_80000000_7FFFFFFF_7FFFFFFF, .fpscr = 0x00040001, .vpr = 0x00000000 }),
    vec("vcvt.s32.f32 #32 nans, infinities and a flushed denormal", .{ .hw1 = 0xEFA0, .hw2 = 0x0F52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x00000123_FF800000_FF800001_7FC00000 }, .{ .qd = 0x00000000_80000000_00000000_00000000, .fpscr = 0x00040081, .vpr = 0x00000000 }),
    vec("vcvt.u32.f32 #1 fractions", .{ .hw1 = 0xFFBF, .hw2 = 0x0F52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xBF333333_3E99999A_BFA00000_3FC00000 }, .{ .qd = 0x00000000_00000000_00000000_00000003, .fpscr = 0x00040011, .vpr = 0x00000000 }),
    vec("vcvt.u32.f32 #16 fractions", .{ .hw1 = 0xFFB0, .hw2 = 0x0F52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xBF333333_3E99999A_BFA00000_3FC00000 }, .{ .qd = 0x00000000_00004CCC_00000000_00018000, .fpscr = 0x00040011, .vpr = 0x00000000 }),
    vec("vcvt.u32.f32 #16 saturation", .{ .hw1 = 0xFFB0, .hw2 = 0x0F52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x40000000_C7000000_47000000_477FFFFD }, .{ .qd = 0x00020000_00000000_80000000_FFFFFD00, .fpscr = 0x00040001, .vpr = 0x00000000 }),
    vec("vcvt.u32.f32 #16 nans, infinities and a flushed denormal", .{ .hw1 = 0xFFB0, .hw2 = 0x0F52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x00000123_FF800000_FF800001_7FC00000 }, .{ .qd = 0x00000000_00000000_00000000_00000000, .fpscr = 0x00040081, .vpr = 0x00000000 }),
    vec("vcvt.u32.f32 #32 fractions", .{ .hw1 = 0xFFA0, .hw2 = 0x0F52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xBF333333_3E99999A_BFA00000_3FC00000 }, .{ .qd = 0x00000000_4CCCCD00_00000000_FFFFFFFF, .fpscr = 0x00040001, .vpr = 0x00000000 }),
    vec("vcvt.u32.f32 #32 saturation", .{ .hw1 = 0xFFA0, .hw2 = 0x0F52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x40000000_C7000000_47000000_477FFFFD }, .{ .qd = 0xFFFFFFFF_00000000_FFFFFFFF_FFFFFFFF, .fpscr = 0x00040001, .vpr = 0x00000000 }),
    vec("vcvt.u32.f32 #32 nans, infinities and a flushed denormal", .{ .hw1 = 0xFFA0, .hw2 = 0x0F52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x00000123_FF800000_FF800001_7FC00000 }, .{ .qd = 0x00000000_00000000_00000000_00000000, .fpscr = 0x00040081, .vpr = 0x00000000 }),
    vec("vcvt.s16.f16 #1 fractions", .{ .hw1 = 0xEFBF, .hw2 = 0x0D52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x868E5640_B8003800_B99A34CD_BD003E00 }, .{ .qd = 0x000000C8_FFFF0001_FFFF0000_FFFE0003, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvt.s16.f16 #8 fractions", .{ .hw1 = 0xEFB8, .hw2 = 0x0D52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x868E5640_B8003800_B99A34CD_BD003E00 }, .{ .qd = 0x00006400_FF800080_FF4D004C_FEC00180, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvt.s16.f16 #8 nans, infinities, subnormals and saturation", .{ .hw1 = 0xEFB8, .hw2 = 0x0D52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xD8005BFF_83FF0001_FC007C00_7C017E00 }, .{ .qd = 0x80007FFF_00000000_80007FFF_00000000, .fpscr = 0x00040011, .vpr = 0x00000000 }),
    vec("vcvt.s16.f16 #16 fractions", .{ .hw1 = 0xEFB0, .hw2 = 0x0D52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x868E5640_B8003800_B99A34CD_BD003E00 }, .{ .qd = 0xFFFA7FFF_80007FFF_80004CD0_80007FFF, .fpscr = 0x00040011, .vpr = 0x00000000 }),
    vec("vcvt.s16.f16 #16 nans, infinities, subnormals and saturation", .{ .hw1 = 0xEFB0, .hw2 = 0x0D52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xD8005BFF_83FF0001_FC007C00_7C017E00 }, .{ .qd = 0x80007FFF_FFFD0000_80007FFF_00000000, .fpscr = 0x00040011, .vpr = 0x00000000 }),
    vec("vcvt.u16.f16 #1 fractions", .{ .hw1 = 0xFFBF, .hw2 = 0x0D52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x868E5640_B8003800_B99A34CD_BD003E00 }, .{ .qd = 0x000000C8_00000001_00000000_00000003, .fpscr = 0x00040011, .vpr = 0x00000000 }),
    vec("vcvt.u16.f16 #8 fractions", .{ .hw1 = 0xFFB8, .hw2 = 0x0D52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x868E5640_B8003800_B99A34CD_BD003E00 }, .{ .qd = 0x00006400_00000080_0000004C_00000180, .fpscr = 0x00040011, .vpr = 0x00000000 }),
    vec("vcvt.u16.f16 #8 nans, infinities, subnormals and saturation", .{ .hw1 = 0xFFB8, .hw2 = 0x0D52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xD8005BFF_83FF0001_FC007C00_7C017E00 }, .{ .qd = 0x0000FFE0_00000000_0000FFFF_00000000, .fpscr = 0x00040011, .vpr = 0x00000000 }),
    vec("vcvt.u16.f16 #16 fractions", .{ .hw1 = 0xFFB0, .hw2 = 0x0D52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x868E5640_B8003800_B99A34CD_BD003E00 }, .{ .qd = 0x0000FFFF_00008000_00004CD0_0000FFFF, .fpscr = 0x00040001, .vpr = 0x00000000 }),
    vec("vcvt.u16.f16 #16 nans, infinities, subnormals and saturation", .{ .hw1 = 0xFFB0, .hw2 = 0x0D52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xD8005BFF_83FF0001_FC007C00_7C017E00 }, .{ .qd = 0x0000FFFF_00000000_0000FFFF_00000000, .fpscr = 0x00040011, .vpr = 0x00000000 }),
};

const from_fixed = [_]V{
    vec("vcvt.f32.s32 #1 set 1", .{ .hw1 = 0xEFBF, .hw2 = 0x0E52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x7FFFFFFF_80000000_FFFFFFFF_00000001 }, .{ .qd = 0x4E800000_CE800000_BF000000_3F000000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvt.f32.s32 #1 set 2", .{ .hw1 = 0xEFBF, .hw2 = 0x0E52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x12345678_FFFF0000_01000001_00000003 }, .{ .qd = 0x4D11A2B4_C7000000_4B000000_3FC00000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvt.f32.s32 #16 set 1", .{ .hw1 = 0xEFB0, .hw2 = 0x0E52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x7FFFFFFF_80000000_FFFFFFFF_00000001 }, .{ .qd = 0x47000000_C7000000_B7800000_37800000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvt.f32.s32 #16 set 2", .{ .hw1 = 0xEFB0, .hw2 = 0x0E52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x12345678_FFFF0000_01000001_00000003 }, .{ .qd = 0x4591A2B4_BF800000_43800000_38400000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvt.f32.s32 #32 set 1", .{ .hw1 = 0xEFA0, .hw2 = 0x0E52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x7FFFFFFF_80000000_FFFFFFFF_00000001 }, .{ .qd = 0x3F000000_BF000000_AF800000_2F800000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvt.f32.s32 #32 set 2", .{ .hw1 = 0xEFA0, .hw2 = 0x0E52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x12345678_FFFF0000_01000001_00000003 }, .{ .qd = 0x3D91A2B4_B7800000_3B800000_30400000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvt.f32.u32 #1 set 1", .{ .hw1 = 0xFFBF, .hw2 = 0x0E52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x7FFFFFFF_80000000_FFFFFFFF_00000001 }, .{ .qd = 0x4E800000_4E800000_4F000000_3F000000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvt.f32.u32 #1 set 2", .{ .hw1 = 0xFFBF, .hw2 = 0x0E52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x12345678_FFFF0000_01000001_00000003 }, .{ .qd = 0x4D11A2B4_4EFFFF00_4B000000_3FC00000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvt.f32.u32 #16 set 1", .{ .hw1 = 0xFFB0, .hw2 = 0x0E52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x7FFFFFFF_80000000_FFFFFFFF_00000001 }, .{ .qd = 0x47000000_47000000_47800000_37800000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvt.f32.u32 #16 set 2", .{ .hw1 = 0xFFB0, .hw2 = 0x0E52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x12345678_FFFF0000_01000001_00000003 }, .{ .qd = 0x4591A2B4_477FFF00_43800000_38400000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvt.f32.u32 #32 set 1", .{ .hw1 = 0xFFA0, .hw2 = 0x0E52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x7FFFFFFF_80000000_FFFFFFFF_00000001 }, .{ .qd = 0x3F000000_3F000000_3F800000_2F800000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvt.f32.u32 #32 set 2", .{ .hw1 = 0xFFA0, .hw2 = 0x0E52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x12345678_FFFF0000_01000001_00000003 }, .{ .qd = 0x3D91A2B4_3F7FFF00_3B800000_30400000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvt.f16.s16 #1 set 1", .{ .hw1 = 0xEFBF, .hw2 = 0x0C52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x1234FF00_08010003_7FFF8000_FFFF0001 }, .{ .qd = 0x688DD800_64003E00_7400F400_B8003800, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvt.f16.s16 #8 set 1", .{ .hw1 = 0xEFB8, .hw2 = 0x0C52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x1234FF00_08010003_7FFF8000_FFFF0001 }, .{ .qd = 0x4C8DBC00_48002200_5800D800_9C001C00, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvt.f16.s16 #16 set 1", .{ .hw1 = 0xEFB0, .hw2 = 0x0C52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x1234FF00_08010003_7FFF8000_FFFF0001 }, .{ .qd = 0x2C8D9C00_28000300_3800B800_81000100, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvt.f16.u16 #1 set 1", .{ .hw1 = 0xFFBF, .hw2 = 0x0C52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x1234FF00_08010003_7FFF8000_FFFF0001 }, .{ .qd = 0x688D77F8_64003E00_74007400_78003800, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvt.f16.u16 #8 set 1", .{ .hw1 = 0xFFB8, .hw2 = 0x0C52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x1234FF00_08010003_7FFF8000_FFFF0001 }, .{ .qd = 0x4C8D5BF8_48002200_58005800_5C001C00, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvt.f16.u16 #16 set 1", .{ .hw1 = 0xFFB0, .hw2 = 0x0C52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x1234FF00_08010003_7FFF8000_FFFF0001 }, .{ .qd = 0x2C8D3BF8_28000300_38003800_3C000100, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvt.f16.s16 #16 with fz16 flushes the subnormal results with ufc", .{ .hw1 = 0xEFB0, .hw2 = 0x0C52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x1234FF00_08010003_7FFF8000_FFFF0001, .fpscr = 0x000C0000 }, .{ .qd = 0x2C8D9C00_28000000_3800B800_80000000, .fpscr = 0x000C0018, .vpr = 0x00000000 }),
    vec("vcvt.s16.f16 #8 with fz16 reads subnormals as zero without idc", .{ .hw1 = 0xEFB8, .hw2 = 0x0D52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xD8005BFF_83FF0001_FC007C00_7C017E00, .fpscr = 0x000C0000 }, .{ .qd = 0x80007FFF_00000000_80007FFF_00000000, .fpscr = 0x000C0001, .vpr = 0x00000000 }),
};

const predicated = [_]V{
    vec("vpt mask keeps lanes 1 and 3", .{ .hw1 = 0xEFB0, .hw2 = 0x0F52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x00000123_FF800000_FF800001_7FC00000, .vpr = 0x00880F0F }, .{ .qd = 0x11112222_80000000_55556666_00000000, .fpscr = 0x00040001, .vpr = 0x00000F0F }),
    vec("a lane with byte 0 off is written but its flags drop", .{ .hw1 = 0xFFB0, .hw2 = 0x0F52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x00000123_FF800000_FF800001_7FC00000, .vpr = 0x0088EEEE }, .{ .qd = 0x00000022_00000044_00000066_00000088, .fpscr = 0x00040000, .vpr = 0x0000EEEE }),
    vec("f16 lanes count flags from their low byte", .{ .hw1 = 0xEFB8, .hw2 = 0x0D52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xD8005BFF_83FF0001_FC007C00_7C017E00, .vpr = 0x0088AAAA }, .{ .qd = 0x80117F22_00330044_80557F66_00770088, .fpscr = 0x00040000, .vpr = 0x0000AAAA }),
    vec("the loop tail on 16-bit lanes stops after lane 2", .{ .hw1 = 0xFFB8, .hw2 = 0x0D52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xD8005BFF_83FF0001_FC007C00_7C017E00, .lr = 3, .fpscr = 0x00010000 }, .{ .qd = 0x11112222_33334444_5555FFFF_00000000, .fpscr = 0x00010001, .vpr = 0x00000000 }),
    vec("eci a0a1 leaves the done beats alone", .{ .hw1 = 0xEFB0, .hw2 = 0x0F52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x40000000_C7000000_47000000_477FFFFD, .it = 0x20 }, .{ .qd = 0x00020000_80000000_55556666_77778888, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("fz, dn and rmode in fpscr are ignored and flags accumulate", .{ .hw1 = 0xEFA0, .hw2 = 0x0E52, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x12345678_FFFF0000_01000001_00000003, .fpscr = 0x03C40001 }, .{ .qd = 0x3D91A2B4_B7800000_3B800000_30400000, .fpscr = 0x03C40011, .vpr = 0x00000000 }),
    vec("qd equal to qm converts in place", .{ .hw1 = 0xEFB8, .hw2 = 0x8F58, .qm = 0xBF333333_3E99999A_BFA00000_3FC00000 }, .{ .qd = 0xFFFFFF4D_0000004C_FFFFFEC0_00000180, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("q7 from q6", .{ .hw1 = 0xFFBC, .hw2 = 0xEC5C, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x1234FF00_08010003_7FFF8000_FFFF0001 }, .{ .qd = 0x5C8D6BF8_58003200_68006800_6C002C00, .fpscr = 0x00040010, .vpr = 0x00000000 }),
};

const unclaimed = [_]V{
    vec("hw2 bit 0 set is unclaimed", .{ .hw1 = 0xEFB0, .hw2 = 0x0D51 }, none),
    vec("m set would name q8 and is unclaimed", .{ .hw1 = 0xEFB0, .hw2 = 0x0D70 }, none),
    vec("hw2 bit 4 clear is unclaimed", .{ .hw1 = 0xEFB0, .hw2 = 0x0D40 }, none),
    vec("hw2 bit 6 clear is unclaimed", .{ .hw1 = 0xEFB0, .hw2 = 0x0D10 }, none),
    vec("hw2 bit 7 set is unclaimed", .{ .hw1 = 0xEFB0, .hw2 = 0x0DD0 }, none),
    vec("hw2 bit 12 set is unclaimed", .{ .hw1 = 0xEFB0, .hw2 = 0x1D50 }, none),
    vec("hw2 bit 10 clear is unclaimed", .{ .hw1 = 0xEFB0, .hw2 = 0x0950 }, none),
    vec("d set would name q8 and is unclaimed", .{ .hw1 = 0xEFF0, .hw2 = 0x0D50 }, none),
    vec("f16 with imm6<4> clear is unclaimed", .{ .hw1 = 0xEFA8, .hw2 = 0x0D50 }, none),
    vec("f32 with imm6<5> clear is unclaimed", .{ .hw1 = 0xEF90, .hw2 = 0x0F50 }, none),
    vec("hw1 bit 7 clear is unclaimed", .{ .hw1 = 0xEF30, .hw2 = 0x0D50 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEFB0, .hw2 = 0x0D50, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
