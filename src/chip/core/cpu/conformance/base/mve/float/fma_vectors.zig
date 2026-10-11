//! Conformance vectors for the decode group `mve.float.fma`
//! (RA8EMU-278): vector VFMA (d + n*m) and VFMS (d + -n*m) on F32 and F16
//! lanes. Expected values are worked from the Arm ARM (DDI0553) FPMulAdd
//! pseudocode under StandardFPSCRValue (round to nearest even, DN and FZ
//! set, FZ16 kept), with one rounding. An F32 denormal operand reads as
//! zero with IDC and a tiny F32 result flushes to zero with UFC; with FZ16
//! an F16 subnormal reads as zero with no flag. Any NaN gives the default
//! NaN (IOC if signalling, or for infinity times zero even with a quiet
//! NaN addend); infinity times zero and opposite infinities are invalid;
//! an exact zero sum is +0; overflow gives infinity with OFC and IXC. A
//! lane runs when any of its bytes is predicated (VPT, loop tail,
//! EPSR.ECI), bytes merge under the mask, and its flags count only when
//! its first byte is. Qd, Qn and Qm are written in that order. Q8 and
//! above, flipped fixed bits and the 16-bit space are unclaimed.
const vector = @import("../../../vector.zig");

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    qd: u128 = 0,
    qn: u128 = 0,
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
const group = "mve_float_fma";
pub const none: Out = .{ .claimed = false, .qd = 0, .fpscr = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = lanes ++ predicated ++ unclaimed;

const lanes = [_]V{
    vec("vfma.f32 ordinary values and rounding", .{ .hw1 = 0xEF02, .hw2 = 0x0C54, .qd = 0x42C80000_322BCC77_BE800000_3F800000, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000, .qm = 0xC0E00000_3E99999A_3F000000_40400000 }, .{ .qd = 0x429E0000_3CF5C296_BFA00000_40B00000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vfma.f32 overflow, infinities and infinity times zero with a qnan addend", .{ .hw1 = 0xEF02, .hw2 = 0x0C54, .qd = 0xFF800000_7FC00000_3F800000_3F800000, .qn = 0x00000000_7F800000_7149F2CA_7149F2CA, .qm = 0x3F800000_00000000_8DA24260_501502F9 }, .{ .qd = 0xFF800000_7FC00000_B29C7F00_7F800000, .fpscr = 0x00040015, .vpr = 0x00000000 }),
    vec("vfma.f32 nans, flushed denormals and signed zeros", .{ .hw1 = 0xEF02, .hw2 = 0x0C54, .qd = 0x7F800001_80000020_80000000_00000000, .qn = 0x80000000_1E3CE508_00000010_7FC00001, .qm = 0x7F800000_1E3CE508_7F800001_40000000 }, .{ .qd = 0x7FC00000_00000000_7FC00000_7FC00000, .fpscr = 0x00040089, .vpr = 0x00000000 }),
    vec("vfma.f32 exact cancellation and zero signs", .{ .hw1 = 0xEF02, .hw2 = 0x0C54, .qd = 0x80000000_3F000000_C1000000_C0C00000, .qn = 0x80000000_3F000000_00000000_40000000, .qm = 0x3E800000_BF800000_40800000_40400000 }, .{ .qd = 0x80000000_00000000_C1000000_00000000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("vfma.f32 a single rounding near the top of the range", .{ .hw1 = 0xEF02, .hw2 = 0x0C54, .qd = 0x7F7FFFFF_BF800000_BF801000_BF801000, .qn = 0x3F800000_3F800800_00000000_3F800800, .qm = 0xBF800800_3F800800_3F800800_3F800800 }, .{ .qd = 0x7F7FFFFF_3A000400_BF801000_33800000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vfma.f16 ordinary values, overflow and subnormals", .{ .hw1 = 0xEF12, .hw2 = 0x0C54, .qd = 0x8000FC00_0002FB53_56401419_B4003C00, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .qm = 0x7C000001_211F5CB0_C70034CD_38004200 }, .{ .qd = 0x7C00FC00_06907753_54F027EF_BD004580, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vfma.f16 infinities, nans and subnormals", .{ .hw1 = 0xEF12, .hw2 = 0x0C54, .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00, .qn = 0x14196400_80000010_3C007E01_00007C00, .qm = 0x14195400_44003800_7C013C00_BC003C00 }, .{ .qd = 0x7E005000_00000000_7E007E00_7E007E00, .fpscr = 0x00040001, .vpr = 0x00000000 }),
    vec("vfms.f32 ordinary values and rounding", .{ .hw1 = 0xEF22, .hw2 = 0x0C54, .qd = 0x42C80000_322BCC77_BE800000_3F800000, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000, .qm = 0xC0E00000_3E99999A_3F000000_40400000 }, .{ .qd = 0x42F20000_BCF5C28B_3F400000_C0600000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vfms.f32 overflow, infinities and infinity times zero with a qnan addend", .{ .hw1 = 0xEF22, .hw2 = 0x0C54, .qd = 0xFF800000_7FC00000_3F800000_3F800000, .qn = 0x00000000_7F800000_7149F2CA_7149F2CA, .qm = 0x3F800000_00000000_8DA24260_501502F9 }, .{ .qd = 0xFF800000_7FC00000_40000000_FF800000, .fpscr = 0x00040015, .vpr = 0x00000000 }),
    vec("vfms.f32 nans, flushed denormals and signed zeros", .{ .hw1 = 0xEF22, .hw2 = 0x0C54, .qd = 0x7F800001_80000020_80000000_00000000, .qn = 0x80000000_1E3CE508_00000010_7FC00001, .qm = 0x7F800000_1E3CE508_7F800001_40000000 }, .{ .qd = 0x7FC00000_80000000_7FC00000_7FC00000, .fpscr = 0x00040089, .vpr = 0x00000000 }),
    vec("vfms.f32 exact cancellation and zero signs", .{ .hw1 = 0xEF22, .hw2 = 0x0C54, .qd = 0x80000000_3F000000_C1000000_C0C00000, .qn = 0x80000000_3F000000_00000000_40000000, .qm = 0x3E800000_BF800000_40800000_40400000 }, .{ .qd = 0x00000000_3F800000_C1000000_C1400000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("vfms.f32 a single rounding near the top of the range", .{ .hw1 = 0xEF22, .hw2 = 0x0C54, .qd = 0x7F7FFFFF_BF800000_BF801000_BF801000, .qn = 0x3F800000_3F800800_00000000_3F800800, .qm = 0xBF800800_3F800800_3F800800_3F800800 }, .{ .qd = 0x7F7FFFFF_C0000800_BF801000_C0001000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vfms.f16 ordinary values, overflow and subnormals", .{ .hw1 = 0xEF32, .hw2 = 0x0C54, .qd = 0x8000FC00_0002FB53_56401419_B4003C00, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .qm = 0x7C000001_211F5CB0_C70034CD_38004200 }, .{ .qd = 0xFC00FC00_868CFC00_5790A76C_3A00C300, .fpscr = 0x00040014, .vpr = 0x00000000 }),
    vec("vfms.f16 infinities, nans and subnormals", .{ .hw1 = 0xEF32, .hw2 = 0x0C54, .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00, .qn = 0x14196400_80000010_3C007E01_00007C00, .qm = 0x14195400_44003800_7C013C00_BC003C00 }, .{ .qd = 0x7E00FC00_00008010_7E007E00_7E00FC00, .fpscr = 0x00040015, .vpr = 0x00000000 }),
    vec("vfma.f16 with fz16 flushes subnormals", .{ .hw1 = 0xEF12, .hw2 = 0x0C54, .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00, .qn = 0x14196400_80000010_3C007E01_00007C00, .qm = 0x14195400_44003800_7C013C00_BC003C00, .fpscr = 0x000C0000 }, .{ .qd = 0x7E005000_00000000_7E007E00_7E007E00, .fpscr = 0x000C0001, .vpr = 0x00000000 }),
    vec("fz, dn and rmode in fpscr are ignored and flags accumulate", .{ .hw1 = 0xEF22, .hw2 = 0x0C54, .qd = 0x42C80000_322BCC77_BE800000_3F800000, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000, .qm = 0xC0E00000_3E99999A_3F000000_40400000, .fpscr = 0x03C40010 }, .{ .qd = 0x42F20000_BCF5C28B_3F400000_C0600000, .fpscr = 0x03C40010, .vpr = 0x00000000 }),
    vec("qn equal to qm squares each lane into the accumulator", .{ .hw1 = 0xEF08, .hw2 = 0x0C58, .qd = 0x42C80000_322BCC77_BE800000_3F800000, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000 }, .{ .qd = 0x42C80000_322BCC77_BE800000_3F800000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("qd equal to qm accumulates onto its own multiplier", .{ .hw1 = 0xEF26, .hw2 = 0xAC5A, .qd = 0x42C80000_322BCC77_BE800000_3F800000, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000 }, .{ .qd = 0x00000000_00000000_00000000_00000000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("q7 from q6 and q5 at f16", .{ .hw1 = 0xEF3C, .hw2 = 0xEC5A, .qd = 0x8000FC00_0002FB53_56401419_B4003C00, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .qm = 0x7C000001_211F5CB0_C70034CD_38004200 }, .{ .qd = 0xFC00FC00_868CFC00_5790A76C_3A00C300, .fpscr = 0x00040014, .vpr = 0x00000000 }),
};

const predicated = [_]V{
    vec("vpt mask keeps lanes 2 and 3", .{ .hw1 = 0xEF02, .hw2 = 0x0C54, .qd = 0x7F800001_80000020_80000000_00000000, .qn = 0x80000000_1E3CE508_00000010_7FC00001, .qm = 0x7F800000_1E3CE508_7F800001_40000000, .vpr = 0x0088FF00 }, .{ .qd = 0x7FC00000_00000000_80000000_00000000, .fpscr = 0x00040089, .vpr = 0x0000FF00 }),
    vec("a lane predicated past its first byte runs without its flags", .{ .hw1 = 0xEF22, .hw2 = 0x0C54, .qd = 0xFF800000_7FC00000_3F800000_3F800000, .qn = 0x00000000_7F800000_7149F2CA_7149F2CA, .qm = 0x3F800000_00000000_8DA24260_501502F9, .vpr = 0x0088E0E0 }, .{ .qd = 0xFF800000_7FC00000_40000000_3F800000, .fpscr = 0x00040000, .vpr = 0x0000E0E0 }),
    vec("odd f16 lanes predicated", .{ .hw1 = 0xEF12, .hw2 = 0x0C54, .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00, .qn = 0x14196400_80000010_3C007E01_00007C00, .qm = 0x14195400_44003800_7C013C00_BC003C00, .vpr = 0x0088CCCC }, .{ .qd = 0x7E00FBFF_00008008_7E004000_7E00FC00, .fpscr = 0x00040001, .vpr = 0x0000CCCC }),
    vec("the loop tail on 16-bit lanes stops after lane 2", .{ .hw1 = 0xEF32, .hw2 = 0x0C54, .qd = 0x8000FC00_0002FB53_56401419_B4003C00, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .qm = 0x7C000001_211F5CB0_C70034CD_38004200, .lr = 3, .fpscr = 0x00010000 }, .{ .qd = 0x8000FC00_0002FB53_5640A76C_3A00C300, .fpscr = 0x00010010, .vpr = 0x00000000 }),
    vec("eci a0a1 leaves the done beats alone", .{ .hw1 = 0xEF02, .hw2 = 0x0C54, .qd = 0xFF800000_7FC00000_3F800000_3F800000, .qn = 0x00000000_7F800000_7149F2CA_7149F2CA, .qm = 0x3F800000_00000000_8DA24260_501502F9, .it = 0x20 }, .{ .qd = 0xFF800000_7FC00000_3F800000_3F800000, .fpscr = 0x00040001, .vpr = 0x00000000 }),
    vec("eci a0a1a2 runs only beat 3", .{ .hw1 = 0xEF32, .hw2 = 0x0C54, .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00, .qn = 0x14196400_80000010_3C007E01_00007C00, .qm = 0x14195400_44003800_7C013C00_BC003C00, .it = 0x40 }, .{ .qd = 0x7E00FC00_00008008_BC004000_7E00FC00, .fpscr = 0x00040015, .vpr = 0x00000000 }),
};

const unclaimed = [_]V{
    vec("hw1 bit 0 set is unclaimed", .{ .hw1 = 0xEF03, .hw2 = 0x0C54 }, none),
    vec("d set would name q8 and is unclaimed", .{ .hw1 = 0xEF42, .hw2 = 0x0C54 }, none),
    vec("hw1 bit 7 set is unclaimed", .{ .hw1 = 0xEF82, .hw2 = 0x0C54 }, none),
    vec("hw2 bit 12 set is unclaimed", .{ .hw1 = 0xEF02, .hw2 = 0x1C54 }, none),
    vec("n set would name q8 and is unclaimed", .{ .hw1 = 0xEF02, .hw2 = 0x0CD4 }, none),
    vec("m set would name q8 and is unclaimed", .{ .hw1 = 0xEF02, .hw2 = 0x0C74 }, none),
    vec("hw2 bit 6 clear is unclaimed", .{ .hw1 = 0xEF02, .hw2 = 0x0C14 }, none),
    vec("hw2 bit 0 set is unclaimed", .{ .hw1 = 0xEF02, .hw2 = 0x0C55 }, none),
    vec("hw2[11:8] other than 1100 is unclaimed", .{ .hw1 = 0xEF02, .hw2 = 0x0D54 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEF02, .hw2 = 0x0C54, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
