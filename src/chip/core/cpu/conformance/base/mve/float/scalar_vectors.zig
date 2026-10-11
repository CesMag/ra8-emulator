//! Conformance vectors for the decode group `mve_float_scalar`
//! (RA8EMU-278): VADD, VSUB, VMUL, VFMA (d + n*Rm) and VFMAS (d*n + Rm) on
//! F32 and F16 lanes with Rm broadcast into every lane (its low half for
//! F16). Expected values are worked from the Arm ARM (DDI0553) FPAdd,
//! FPSub, FPMul and FPMulAdd pseudocode under StandardFPSCRValue (round to
//! nearest even, DN and FZ set, FZ16 kept). An F32 denormal operand reads
//! as zero with IDC and a tiny F32 result flushes to zero with UFC; with
//! FZ16 an F16 subnormal reads as zero with no flag. NaNs give the default
//! NaN (IOC if signalling or invalid); overflow gives infinity with OFC
//! and IXC. A lane runs when any of its bytes is predicated (VPT, loop
//! tail, EPSR.ECI), bytes merge under the mask, and its flags count only
//! when its first byte is. Qd then Qn are written, then Rm. Rm of SP or
//! PC, swapped B bits, Q8 and above, flipped fixed bits and the 16-bit
//! space are unclaimed.
const vector = @import("../../../vector.zig");

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    qd: u128 = 0,
    qn: u128 = 0,
    rm: u32 = 0,
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
const group = "mve_float_scalar";
pub const none: Out = .{ .claimed = false, .qd = 0, .fpscr = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = lanes ++ predicated ++ unclaimed;

const lanes = [_]V{
    vec("vadd.f32 against 3.0", .{ .hw1 = 0xEE32, .hw2 = 0x0F42, .qd = 0x42C80000_322BCC77_BE800000_3F800000, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000, .rm = 0x40400000 }, .{ .qd = 0x40C00000_40466666_3F800000_40900000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vadd.f32 against 1e10, with overflow and infinity times zero", .{ .hw1 = 0xEE32, .hw2 = 0x0F42, .qd = 0xFF800000_7FC00000_3F800000_3F800000, .qn = 0x00000000_7F800000_7149F2CA_7149F2CA, .rm = 0x501502F9 }, .{ .qd = 0x501502F9_7F800000_7149F2CA_7149F2CA, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vadd.f32 against a signalling nan", .{ .hw1 = 0xEE32, .hw2 = 0x0F42, .qd = 0x7F800001_80000020_80000000_00000000, .qn = 0x80000000_1E3CE508_00000010_7FC00001, .rm = 0x7F800001 }, .{ .qd = 0x7FC00000_7FC00000_7FC00000_7FC00000, .fpscr = 0x00040081, .vpr = 0x00000000 }),
    vec("vadd.f32 against -0.0", .{ .hw1 = 0xEE32, .hw2 = 0x0F42, .qd = 0x80000000_3F000000_C1000000_C0C00000, .qn = 0x80000000_3F000000_00000000_40000000, .rm = 0x80000000 }, .{ .qd = 0x80000000_3F000000_00000000_40000000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("vadd.f32 against infinity", .{ .hw1 = 0xEE32, .hw2 = 0x0F42, .qd = 0x42C80000_322BCC77_BE800000_3F800000, .qn = 0x00000000_7F800000_7149F2CA_7149F2CA, .rm = 0x7F800000 }, .{ .qd = 0x7F800000_7F800000_7F800000_7F800000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("vadd.f32 against a denormal, which reads as zero with idc", .{ .hw1 = 0xEE32, .hw2 = 0x0F42, .qd = 0xFF800000_7FC00000_3F800000_3F800000, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000, .rm = 0x10 }, .{ .qd = 0x40400000_3DCCCCCD_C0000000_3FC00000, .fpscr = 0x00040080, .vpr = 0x00000000 }),
    vec("vadd.f32 against the largest finite value", .{ .hw1 = 0xEE32, .hw2 = 0x0F42, .qd = 0x7F7FFFFF_BF800000_BF801000_BF801000, .qn = 0x3F800000_3F800800_00000000_3F800800, .rm = 0x7F7FFFFF }, .{ .qd = 0x7F7FFFFF_7F7FFFFF_7F7FFFFF_7F7FFFFF, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vadd.f16 against 3.0 with junk in the high half of rm", .{ .hw1 = 0xFE32, .hw2 = 0x0F42, .qd = 0x8000FC00_0002FB53_56401419_B4003C00, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .rm = 0xDEAD4200 }, .{ .qd = 0x45004100_42055CBC_46004233_3C004480, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vadd.f16 against infinity", .{ .hw1 = 0xFE32, .hw2 = 0x0F42, .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00, .qn = 0x14196400_80000010_3C007E01_00007C00, .rm = 0x17C00 }, .{ .qd = 0x7C007C00_7C007C00_7C007E00_7C007C00, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("vadd.f16 against a subnormal", .{ .hw1 = 0xFE32, .hw2 = 0x0F42, .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .rm = 0x12340001 }, .{ .qd = 0x4000B800_211F5CB0_42002E66_C0003E00, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vsub.f32 against 3.0", .{ .hw1 = 0xEE32, .hw2 = 0x1F42, .qd = 0x42C80000_322BCC77_BE800000_3F800000, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000, .rm = 0x40400000 }, .{ .qd = 0x00000000_C039999A_C0A00000_BFC00000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vsub.f32 against 1e10, with overflow and infinity times zero", .{ .hw1 = 0xEE32, .hw2 = 0x1F42, .qd = 0xFF800000_7FC00000_3F800000_3F800000, .qn = 0x00000000_7F800000_7149F2CA_7149F2CA, .rm = 0x501502F9 }, .{ .qd = 0xD01502F9_7F800000_7149F2CA_7149F2CA, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vsub.f32 against a signalling nan", .{ .hw1 = 0xEE32, .hw2 = 0x1F42, .qd = 0x7F800001_80000020_80000000_00000000, .qn = 0x80000000_1E3CE508_00000010_7FC00001, .rm = 0x7F800001 }, .{ .qd = 0x7FC00000_7FC00000_7FC00000_7FC00000, .fpscr = 0x00040081, .vpr = 0x00000000 }),
    vec("vsub.f32 against -0.0", .{ .hw1 = 0xEE32, .hw2 = 0x1F42, .qd = 0x80000000_3F000000_C1000000_C0C00000, .qn = 0x80000000_3F000000_00000000_40000000, .rm = 0x80000000 }, .{ .qd = 0x00000000_3F000000_00000000_40000000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("vsub.f32 against infinity", .{ .hw1 = 0xEE32, .hw2 = 0x1F42, .qd = 0x42C80000_322BCC77_BE800000_3F800000, .qn = 0x00000000_7F800000_7149F2CA_7149F2CA, .rm = 0x7F800000 }, .{ .qd = 0xFF800000_7FC00000_FF800000_FF800000, .fpscr = 0x00040001, .vpr = 0x00000000 }),
    vec("vsub.f32 against a denormal, which reads as zero with idc", .{ .hw1 = 0xEE32, .hw2 = 0x1F42, .qd = 0xFF800000_7FC00000_3F800000_3F800000, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000, .rm = 0x10 }, .{ .qd = 0x40400000_3DCCCCCD_C0000000_3FC00000, .fpscr = 0x00040080, .vpr = 0x00000000 }),
    vec("vsub.f32 against the largest finite value", .{ .hw1 = 0xEE32, .hw2 = 0x1F42, .qd = 0x7F7FFFFF_BF800000_BF801000_BF801000, .qn = 0x3F800000_3F800800_00000000_3F800800, .rm = 0x7F7FFFFF }, .{ .qd = 0xFF7FFFFF_FF7FFFFF_FF7FFFFF_FF7FFFFF, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vsub.f16 against 3.0 with junk in the high half of rm", .{ .hw1 = 0xFE32, .hw2 = 0x1F42, .qd = 0x8000FC00_0002FB53_56401419_B4003C00, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .rm = 0xDEAD4200 }, .{ .qd = 0xBC00C300_C1FB5CA4_0000C1CD_C500BE00, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vsub.f16 against infinity", .{ .hw1 = 0xFE32, .hw2 = 0x1F42, .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00, .qn = 0x14196400_80000010_3C007E01_00007C00, .rm = 0x17C00 }, .{ .qd = 0xFC00FC00_FC00FC00_FC007E00_FC007E00, .fpscr = 0x00040001, .vpr = 0x00000000 }),
    vec("vsub.f16 against a subnormal", .{ .hw1 = 0xFE32, .hw2 = 0x1F42, .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .rm = 0x12340001 }, .{ .qd = 0x4000B800_211F5CB0_42002E66_C0003E00, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vmul.f32 against 3.0", .{ .hw1 = 0xEE33, .hw2 = 0x0E62, .qd = 0x42C80000_322BCC77_BE800000_3F800000, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000, .rm = 0x40400000 }, .{ .qd = 0x41100000_3E99999A_C0C00000_40900000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vmul.f32 against 1e10, with overflow and infinity times zero", .{ .hw1 = 0xEE33, .hw2 = 0x0E62, .qd = 0xFF800000_7FC00000_3F800000_3F800000, .qn = 0x00000000_7F800000_7149F2CA_7149F2CA, .rm = 0x501502F9 }, .{ .qd = 0x00000000_7F800000_7F800000_7F800000, .fpscr = 0x00040014, .vpr = 0x00000000 }),
    vec("vmul.f32 against a signalling nan", .{ .hw1 = 0xEE33, .hw2 = 0x0E62, .qd = 0x7F800001_80000020_80000000_00000000, .qn = 0x80000000_1E3CE508_00000010_7FC00001, .rm = 0x7F800001 }, .{ .qd = 0x7FC00000_7FC00000_7FC00000_7FC00000, .fpscr = 0x00040081, .vpr = 0x00000000 }),
    vec("vmul.f32 against -0.0", .{ .hw1 = 0xEE33, .hw2 = 0x0E62, .qd = 0x80000000_3F000000_C1000000_C0C00000, .qn = 0x80000000_3F000000_00000000_40000000, .rm = 0x80000000 }, .{ .qd = 0x00000000_80000000_80000000_80000000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("vmul.f32 against infinity", .{ .hw1 = 0xEE33, .hw2 = 0x0E62, .qd = 0x42C80000_322BCC77_BE800000_3F800000, .qn = 0x00000000_7F800000_7149F2CA_7149F2CA, .rm = 0x7F800000 }, .{ .qd = 0x7FC00000_7F800000_7F800000_7F800000, .fpscr = 0x00040001, .vpr = 0x00000000 }),
    vec("vmul.f32 against a denormal, which reads as zero with idc", .{ .hw1 = 0xEE33, .hw2 = 0x0E62, .qd = 0xFF800000_7FC00000_3F800000_3F800000, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000, .rm = 0x10 }, .{ .qd = 0x00000000_00000000_80000000_00000000, .fpscr = 0x00040080, .vpr = 0x00000000 }),
    vec("vmul.f32 against the largest finite value", .{ .hw1 = 0xEE33, .hw2 = 0x0E62, .qd = 0x7F7FFFFF_BF800000_BF801000_BF801000, .qn = 0x3F800000_3F800800_00000000_3F800800, .rm = 0x7F7FFFFF }, .{ .qd = 0x7F7FFFFF_7F800000_00000000_7F800000, .fpscr = 0x00040014, .vpr = 0x00000000 }),
    vec("vmul.f16 against 3.0 with junk in the high half of rm", .{ .hw1 = 0xFE33, .hw2 = 0x0E62, .qd = 0x8000FC00_0002FB53_56401419_B4003C00, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .rm = 0xDEAD4200 }, .{ .qd = 0x4600BE00_27AE6308_488034CC_C6004480, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vmul.f16 against infinity", .{ .hw1 = 0xFE33, .hw2 = 0x0E62, .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00, .qn = 0x14196400_80000010_3C007E01_00007C00, .rm = 0x17C00 }, .{ .qd = 0x7C007C00_7E007C00_7C007E00_7E007C00, .fpscr = 0x00040001, .vpr = 0x00000000 }),
    vec("vmul.f16 against a subnormal", .{ .hw1 = 0xFE33, .hw2 = 0x0E62, .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .rm = 0x12340001 }, .{ .qd = 0x00028000_0000012C_00030000_80020002, .fpscr = 0x00040018, .vpr = 0x00000000 }),
    vec("vfma.f32 against 3.0", .{ .hw1 = 0xEE33, .hw2 = 0x0E42, .qd = 0x42C80000_322BCC77_BE800000_3F800000, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000, .rm = 0x40400000 }, .{ .qd = 0x42DA0000_3E99999A_C0C80000_40B00000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vfma.f32 against 1e10, with overflow and infinity times zero", .{ .hw1 = 0xEE33, .hw2 = 0x0E42, .qd = 0xFF800000_7FC00000_3F800000_3F800000, .qn = 0x00000000_7F800000_7149F2CA_7149F2CA, .rm = 0x501502F9 }, .{ .qd = 0xFF800000_7FC00000_7F800000_7F800000, .fpscr = 0x00040014, .vpr = 0x00000000 }),
    vec("vfma.f32 against a signalling nan", .{ .hw1 = 0xEE33, .hw2 = 0x0E42, .qd = 0x7F800001_80000020_80000000_00000000, .qn = 0x80000000_1E3CE508_00000010_7FC00001, .rm = 0x7F800001 }, .{ .qd = 0x7FC00000_7FC00000_7FC00000_7FC00000, .fpscr = 0x00040081, .vpr = 0x00000000 }),
    vec("vfma.f32 against -0.0", .{ .hw1 = 0xEE33, .hw2 = 0x0E42, .qd = 0x80000000_3F000000_C1000000_C0C00000, .qn = 0x80000000_3F000000_00000000_40000000, .rm = 0x80000000 }, .{ .qd = 0x00000000_3F000000_C1000000_C0C00000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("vfma.f32 against infinity", .{ .hw1 = 0xEE33, .hw2 = 0x0E42, .qd = 0x42C80000_322BCC77_BE800000_3F800000, .qn = 0x00000000_7F800000_7149F2CA_7149F2CA, .rm = 0x7F800000 }, .{ .qd = 0x7FC00000_7F800000_7F800000_7F800000, .fpscr = 0x00040001, .vpr = 0x00000000 }),
    vec("vfma.f32 against a denormal, which reads as zero with idc", .{ .hw1 = 0xEE33, .hw2 = 0x0E42, .qd = 0xFF800000_7FC00000_3F800000_3F800000, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000, .rm = 0x10 }, .{ .qd = 0xFF800000_7FC00000_3F800000_3F800000, .fpscr = 0x00040080, .vpr = 0x00000000 }),
    vec("vfma.f32 against the largest finite value", .{ .hw1 = 0xEE33, .hw2 = 0x0E42, .qd = 0x7F7FFFFF_BF800000_BF801000_BF801000, .qn = 0x3F800000_3F800800_00000000_3F800800, .rm = 0x7F7FFFFF }, .{ .qd = 0x7F800000_7F800000_BF801000_7F800000, .fpscr = 0x00040014, .vpr = 0x00000000 }),
    vec("vfma.f16 against 3.0 with junk in the high half of rm", .{ .hw1 = 0xFE33, .hw2 = 0x0E42, .qd = 0x8000FC00_0002FB53_56401419_B4003C00, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .rm = 0xDEAD4200 }, .{ .qd = 0x4600FC00_27AFFB37_56D034D1_C6404580, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vfma.f16 against infinity", .{ .hw1 = 0xFE33, .hw2 = 0x0E42, .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00, .qn = 0x14196400_80000010_3C007E01_00007C00, .rm = 0x17C00 }, .{ .qd = 0x7E007C00_7E007C00_7C007E00_7E007E00, .fpscr = 0x00040001, .vpr = 0x00000000 }),
    vec("vfma.f16 against a subnormal", .{ .hw1 = 0xFE33, .hw2 = 0x0E42, .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .rm = 0x12340001 }, .{ .qd = 0x7E00FBFF_00000124_BC004000_7E00FC00, .fpscr = 0x00040019, .vpr = 0x00000000 }),
    vec("vfmas.f32 against 3.0", .{ .hw1 = 0xEE33, .hw2 = 0x1E42, .qd = 0x42C80000_322BCC77_BE800000_3F800000, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000, .rm = 0x40400000 }, .{ .qd = 0x43978000_40400000_40600000_40900000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vfmas.f32 against 1e10, with overflow and infinity times zero", .{ .hw1 = 0xEE33, .hw2 = 0x1E42, .qd = 0xFF800000_7FC00000_3F800000_3F800000, .qn = 0x00000000_7F800000_7149F2CA_7149F2CA, .rm = 0x501502F9 }, .{ .qd = 0x7FC00000_7FC00000_7149F2CA_7149F2CA, .fpscr = 0x00040011, .vpr = 0x00000000 }),
    vec("vfmas.f32 against a signalling nan", .{ .hw1 = 0xEE33, .hw2 = 0x1E42, .qd = 0x7F800001_80000020_80000000_00000000, .qn = 0x80000000_1E3CE508_00000010_7FC00001, .rm = 0x7F800001 }, .{ .qd = 0x7FC00000_7FC00000_7FC00000_7FC00000, .fpscr = 0x00040081, .vpr = 0x00000000 }),
    vec("vfmas.f32 against -0.0", .{ .hw1 = 0xEE33, .hw2 = 0x1E42, .qd = 0x80000000_3F000000_C1000000_C0C00000, .qn = 0x80000000_3F000000_00000000_40000000, .rm = 0x80000000 }, .{ .qd = 0x00000000_3E800000_80000000_C1400000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("vfmas.f32 against infinity", .{ .hw1 = 0xEE33, .hw2 = 0x1E42, .qd = 0x42C80000_322BCC77_BE800000_3F800000, .qn = 0x00000000_7F800000_7149F2CA_7149F2CA, .rm = 0x7F800000 }, .{ .qd = 0x7F800000_7F800000_7F800000_7F800000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("vfmas.f32 against a denormal, which reads as zero with idc", .{ .hw1 = 0xEE33, .hw2 = 0x1E42, .qd = 0xFF800000_7FC00000_3F800000_3F800000, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000, .rm = 0x10 }, .{ .qd = 0xFF800000_7FC00000_C0000000_3FC00000, .fpscr = 0x00040080, .vpr = 0x00000000 }),
    vec("vfmas.f32 against the largest finite value", .{ .hw1 = 0xEE33, .hw2 = 0x1E42, .qd = 0x7F7FFFFF_BF800000_BF801000_BF801000, .qn = 0x3F800000_3F800800_00000000_3F800800, .rm = 0x7F7FFFFF }, .{ .qd = 0x7F800000_7F7FFFFF_7F7FFFFF_7F7FFFFF, .fpscr = 0x00040014, .vpr = 0x00000000 }),
    vec("vfmas.f16 against 3.0 with junk in the high half of rm", .{ .hw1 = 0xFE33, .hw2 = 0x1E42, .qd = 0x8000FC00_0002FB53_56401419_B4003C00, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .rm = 0xDEAD4200 }, .{ .qd = 0x42007C00_4200FC00_5CBC4200_43004480, .fpscr = 0x00040014, .vpr = 0x00000000 }),
    vec("vfmas.f16 against infinity", .{ .hw1 = 0xFE33, .hw2 = 0x1E42, .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00, .qn = 0x14196400_80000010_3C007E01_00007C00, .rm = 0x17C00 }, .{ .qd = 0x7E007C00_7C007C00_7C007E00_7E007E00, .fpscr = 0x00040001, .vpr = 0x00000000 }),
    vec("vfmas.f16 against a subnormal", .{ .hw1 = 0xFE33, .hw2 = 0x1E42, .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .rm = 0x12340001 }, .{ .qd = 0x7E0077FF_000188B0_C2003266_7E00FC00, .fpscr = 0x00040011, .vpr = 0x00000000 }),
    vec("vfma.f16 with fz16 flushes subnormals", .{ .hw1 = 0xFE33, .hw2 = 0x0E42, .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00, .qn = 0x14196400_80000010_3C007E01_00007C00, .rm = 0x1, .fpscr = 0x000C0000 }, .{ .qd = 0x7E00FBFF_00000000_BC007E00_7E007E00, .fpscr = 0x000C0001, .vpr = 0x00000000 }),
    vec("vmul.f16 with fz16 flushes a subnormal scalar", .{ .hw1 = 0xFE33, .hw2 = 0x0E62, .qd = 0x8000FC00_0002FB53_56401419_B4003C00, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .rm = 0x1, .fpscr = 0x000C0000 }, .{ .qd = 0x00008000_00000000_00000000_80000000, .fpscr = 0x000C0000, .vpr = 0x00000000 }),
    vec("fz, dn and rmode in fpscr are ignored and flags accumulate", .{ .hw1 = 0xEE33, .hw2 = 0x1E42, .qd = 0x42C80000_322BCC77_BE800000_3F800000, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000, .rm = 0x3E99999A, .fpscr = 0x03C40010 }, .{ .qd = 0x43962666_3E99999A_3F4CCCCD_3FE66666, .fpscr = 0x03C40010, .vpr = 0x00000000 }),
    vec("vsub of a lane equal to rm gives +0", .{ .hw1 = 0xEE32, .hw2 = 0x1F42, .qd = 0x42C80000_322BCC77_BE800000_3F800000, .qn = 0x00000000_40200000_C0200000_40200000, .rm = 0x40200000 }, .{ .qd = 0xC0200000_00000000_C0A00000_00000000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("qd equal to qn accumulates onto its own multiplier", .{ .hw1 = 0xEE3B, .hw2 = 0xAE44, .qd = 0x42C80000_322BCC77_BE800000_3F800000, .rm = 0xBFC00000 }, .{ .qd = 0x00000000_00000000_00000000_00000000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("vfmas with qd equal to qn squares each lane", .{ .hw1 = 0xEE37, .hw2 = 0x7E4C, .qd = 0x40400000_3DCCCCCD_C0000000_3FC00000, .rm = 0x3F800000 }, .{ .qd = 0x3F800000_3F800000_3F800000_3F800000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("q7 from q6 and lr at f16", .{ .hw1 = 0xFE3D, .hw2 = 0xFE4E, .qd = 0x8000FC00_0002FB53_56401419_B4003C00, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .rm = 0x3C00, .lr = 15360 }, .{ .qd = 0x3C007C00_3C00FC00_5CB43C00_3E004100, .fpscr = 0x00040014, .vpr = 0x00000000 }),
};

const predicated = [_]V{
    vec("vpt mask keeps lanes 2 and 3", .{ .hw1 = 0xEE33, .hw2 = 0x0E42, .qd = 0x7F800001_80000020_80000000_00000000, .qn = 0x80000000_1E3CE508_00000010_7FC00001, .rm = 0x40000000, .vpr = 0x0088FF00 }, .{ .qd = 0x7FC00000_1EBCE508_80000000_00000000, .fpscr = 0x00040081, .vpr = 0x0000FF00 }),
    vec("a lane predicated past its first byte runs without its flags", .{ .hw1 = 0xEE33, .hw2 = 0x0E62, .qd = 0xFF800000_7FC00000_3F800000_3F800000, .qn = 0x00000000_7F800000_7149F2CA_7149F2CA, .rm = 0x501502F9, .vpr = 0x0088E0E0 }, .{ .qd = 0x00000000_7FC00000_7F800000_3F800000, .fpscr = 0x00040000, .vpr = 0x0000E0E0 }),
    vec("odd f16 lanes predicated", .{ .hw1 = 0xFE32, .hw2 = 0x0F42, .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00, .qn = 0x14196400_80000010_3C007E01_00007C00, .rm = 0x7C00, .vpr = 0x0088CCCC }, .{ .qd = 0x7C00FBFF_7C008008_7C004000_7C00FC00, .fpscr = 0x00040000, .vpr = 0x0000CCCC }),
    vec("the loop tail on 16-bit lanes stops after lane 2", .{ .hw1 = 0xFE32, .hw2 = 0x1F42, .qd = 0x8000FC00_0002FB53_56401419_B4003C00, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .rm = 0x4200, .lr = 3, .fpscr = 0x00010000 }, .{ .qd = 0x8000FC00_0002FB53_5640C1CD_C500BE00, .fpscr = 0x00010010, .vpr = 0x00000000 }),
    vec("eci a0a1 leaves the done beats alone", .{ .hw1 = 0xEE33, .hw2 = 0x1E42, .qd = 0xFF800000_7FC00000_3F800000_3F800000, .qn = 0x00000000_7F800000_7149F2CA_7149F2CA, .rm = 0x501502F9, .it = 0x20 }, .{ .qd = 0x7FC00000_7FC00000_3F800000_3F800000, .fpscr = 0x00040001, .vpr = 0x00000000 }),
    vec("eci a0a1a2 runs only beat 3", .{ .hw1 = 0xFE33, .hw2 = 0x0E62, .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00, .qn = 0x14196400_80000010_3C007E01_00007C00, .rm = 0x1, .it = 0x40 }, .{ .qd = 0x00000400_00008008_BC004000_7E00FC00, .fpscr = 0x00040018, .vpr = 0x00000000 }),
};

const unclaimed = [_]V{
    vec("rm of sp is unclaimed", .{ .hw1 = 0xEE33, .hw2 = 0x0E4D }, none),
    vec("rm of pc is unclaimed", .{ .hw1 = 0xEE30, .hw2 = 0x0F4F }, none),
    vec("vmul with b clear is unclaimed", .{ .hw1 = 0xEE32, .hw2 = 0x0E62 }, none),
    vec("vadd with b set is unclaimed", .{ .hw1 = 0xEE33, .hw2 = 0x0F42 }, none),
    vec("d set would name q8 and is unclaimed", .{ .hw1 = 0xEE73, .hw2 = 0x0E42 }, none),
    vec("hw1 bit 8 set is unclaimed", .{ .hw1 = 0xEF33, .hw2 = 0x0E42 }, none),
    vec("n set would name q8 and is unclaimed", .{ .hw1 = 0xEE33, .hw2 = 0x0EC2 }, none),
    vec("hw2 bit 5 set on vadd is unclaimed", .{ .hw1 = 0xEE32, .hw2 = 0x0F62 }, none),
    vec("hw2 bit 12 set on vmul is unclaimed", .{ .hw1 = 0xEE33, .hw2 = 0x1E62 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEE33, .hw2 = 0x0E42, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
