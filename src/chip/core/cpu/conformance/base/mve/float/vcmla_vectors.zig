//! Conformance vectors for the decode group `mve_float_vcmla`
//! (RA8EMU-278): VCMLA on F32 and F16 lane pairs, rotations 0, 90, 180 and
//! 270. Expected values are worked from the Arm ARM (DDI0553) pseudocode:
//! Qd (re, im) gains (n.re*m.re, n.re*m.im) at 0, (n.im*-m.im, n.im*m.re)
//! at 90, (n.re*-m.re, n.re*-m.im) at 180 and (n.im*m.im, n.im*-m.re) at
//! 270, each one FPMulAdd (a single rounding) under StandardFPSCRValue
//! (round to nearest even, DN and FZ set, FZ16 kept). An F32 denormal
//! operand reads as zero with IDC and a tiny F32 result flushes to zero
//! with UFC; with FZ16 an F16 subnormal reads as zero with no flag. Any NaN
//! gives the default NaN (IOC if signalling, or for infinity times zero
//! even with a quiet NaN addend); infinity times zero and opposite
//! infinities are invalid; an exact zero sum is +0; overflow gives
//! infinity with OFC and IXC. A pair runs when any of its bytes is predicated (VPT,
//! loop tail, EPSR.ECI), bytes merge under the mask, and each half's
//! flags count only when that half's first byte is. Qd, Qn and Qm are
//! written in that order; Qd never equals Qn or Qm here (UNPREDICTABLE at
//! F32). Q8 and above, flipped fixed bits and the 16-bit space are
//! unclaimed.
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
const group = "mve_float_vcmla";
pub const none: Out = .{ .claimed = false, .qd = 0, .fpscr = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = rotations ++ predicated ++ unclaimed;

const rotations = [_]V{
    vec("vcmla.f32 #0 ordinary values and rounding", .{ .hw1 = 0xFC32, .hw2 = 0x0844, .qd = 0x42C80000_322BCC77_BE800000_3F800000, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000, .qm = 0xC0E00000_3E99999A_3F000000_40400000 }, .{ .qd = 0x42C6999A_3CF5C296_3F000000_40B00000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcmla.f32 #0 overflow, infinities and infinity times zero with a qnan addend", .{ .hw1 = 0xFC32, .hw2 = 0x0844, .qd = 0xFF800000_7FC00000_3F800000_3F800000, .qn = 0x00000000_7F800000_7149F2CA_7149F2CA, .qm = 0x3F800000_00000000_8DA24260_501502F9 }, .{ .qd = 0x7FC00000_7FC00000_B29C7F00_7F800000, .fpscr = 0x00040015, .vpr = 0x00000000 }),
    vec("vcmla.f32 #0 nans, flushed denormals and signed zeros", .{ .hw1 = 0xFC32, .hw2 = 0x0844, .qd = 0x7F800001_80000020_80000000_00000000, .qn = 0x80000000_1E3CE508_00000010_7FC00001, .qm = 0x7F800000_1E3CE508_7F800001_40000000 }, .{ .qd = 0x7FC00000_00000000_7FC00000_7FC00000, .fpscr = 0x00040089, .vpr = 0x00000000 }),
    vec("vcmla.f32 #0 exact cancellation and zero signs", .{ .hw1 = 0xFC32, .hw2 = 0x0844, .qd = 0x80000000_3F000000_C1000000_C0C00000, .qn = 0x80000000_3F000000_00000000_40000000, .qm = 0x3E800000_BF800000_40800000_40400000 }, .{ .qd = 0x3E000000_00000000_00000000_00000000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("vcmla.f16 #0 ordinary values, overflow and subnormals", .{ .hw1 = 0xFC22, .hw2 = 0x0844, .qd = 0x8000FC00_0002FB53_56401419_B4003C00, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .qm = 0x7C000001_211F5CB0_C70034CD_38004200 }, .{ .qd = 0xFC00FC00_42007753_563527EF_38004580, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcmla.f16 #0 infinities, nans and subnormals", .{ .hw1 = 0xFC22, .hw2 = 0x0844, .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00, .qn = 0x14196400_80000010_3C007E01_00007C00, .qm = 0x14195400_44003800_7C013C00_BC003C00 }, .{ .qd = 0x7E005000_00400000_7E007E00_7E007E00, .fpscr = 0x00040001, .vpr = 0x00000000 }),
    vec("vcmla.f32 #90 ordinary values and rounding", .{ .hw1 = 0xFCB2, .hw2 = 0x0844, .qd = 0x42C80000_322BCC77_BE800000_3F800000, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000, .qm = 0xC0E00000_3E99999A_3F000000_40400000 }, .{ .qd = 0x42C9CCCD_41A80000_C0C80000_40000000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcmla.f32 #90 overflow, infinities and infinity times zero with a qnan addend", .{ .hw1 = 0xFCB2, .hw2 = 0x0844, .qd = 0xFF800000_7FC00000_3F800000_3F800000, .qn = 0x00000000_7F800000_7149F2CA_7149F2CA, .qm = 0x3F800000_00000000_8DA24260_501502F9 }, .{ .qd = 0xFF800000_7FC00000_7F800000_40000000, .fpscr = 0x00040014, .vpr = 0x00000000 }),
    vec("vcmla.f32 #90 nans, flushed denormals and signed zeros", .{ .hw1 = 0xFCB2, .hw2 = 0x0844, .qd = 0x7F800001_80000020_80000000_00000000, .qn = 0x80000000_1E3CE508_00000010_7FC00001, .qm = 0x7F800000_1E3CE508_7F800001_40000000 }, .{ .qd = 0x7FC00000_7FC00000_00000000_7FC00000, .fpscr = 0x00040081, .vpr = 0x00000000 }),
    vec("vcmla.f32 #90 exact cancellation and zero signs", .{ .hw1 = 0xFCB2, .hw2 = 0x0844, .qd = 0x80000000_3F000000_C1000000_C0C00000, .qn = 0x80000000_3F000000_00000000_40000000, .qm = 0x3E800000_BF800000_40800000_40400000 }, .{ .qd = 0x00000000_3F000000_C1000000_C0C00000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("vcmla.f16 #90 ordinary values, overflow and subnormals", .{ .hw1 = 0xFCA2, .hw2 = 0x0844, .qd = 0x8000FC00_0002FB53_56401419_B4003C00, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .qm = 0x7C000001_211F5CB0_C70034CD_38004200 }, .{ .qd = 0x0002FC00_4200FB53_564E4D40_C6404000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcmla.f16 #90 infinities, nans and subnormals", .{ .hw1 = 0xFCA2, .hw2 = 0x0844, .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00, .qn = 0x14196400_80000010_3C007E01_00007C00, .qm = 0x14195400_44003800_7C013C00_BC003C00 }, .{ .qd = 0x7E00FBFF_00008008_00007E00_7E00FC00, .fpscr = 0x00040011, .vpr = 0x00000000 }),
    vec("vcmla.f32 #180 ordinary values and rounding", .{ .hw1 = 0xFD32, .hw2 = 0x0844, .qd = 0x42C80000_322BCC77_BE800000_3F800000, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000, .qm = 0xC0E00000_3E99999A_3F000000_40400000 }, .{ .qd = 0x42C96666_BCF5C28B_BF800000_C0600000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcmla.f32 #180 overflow, infinities and infinity times zero with a qnan addend", .{ .hw1 = 0xFD32, .hw2 = 0x0844, .qd = 0xFF800000_7FC00000_3F800000_3F800000, .qn = 0x00000000_7F800000_7149F2CA_7149F2CA, .qm = 0x3F800000_00000000_8DA24260_501502F9 }, .{ .qd = 0xFF800000_7FC00000_40000000_FF800000, .fpscr = 0x00040015, .vpr = 0x00000000 }),
    vec("vcmla.f32 #180 nans, flushed denormals and signed zeros", .{ .hw1 = 0xFD32, .hw2 = 0x0844, .qd = 0x7F800001_80000020_80000000_00000000, .qn = 0x80000000_1E3CE508_00000010_7FC00001, .qm = 0x7F800000_1E3CE508_7F800001_40000000 }, .{ .qd = 0x7FC00000_80000000_7FC00000_7FC00000, .fpscr = 0x00040089, .vpr = 0x00000000 }),
    vec("vcmla.f32 #180 exact cancellation and zero signs", .{ .hw1 = 0xFD32, .hw2 = 0x0844, .qd = 0x80000000_3F000000_C1000000_C0C00000, .qn = 0x80000000_3F000000_00000000_40000000, .qm = 0x3E800000_BF800000_40800000_40400000 }, .{ .qd = 0xBE000000_3F800000_C1800000_C1400000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("vcmla.f16 #180 ordinary values, overflow and subnormals", .{ .hw1 = 0xFD22, .hw2 = 0x0844, .qd = 0x8000FC00_0002FB53_56401419_B4003C00, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .qm = 0x7C000001_211F5CB0_C70034CD_38004200 }, .{ .qd = 0x7C00FC00_C200FC00_564BA76C_BC00C300, .fpscr = 0x00040014, .vpr = 0x00000000 }),
    vec("vcmla.f16 #180 infinities, nans and subnormals", .{ .hw1 = 0xFD22, .hw2 = 0x0844, .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00, .qn = 0x14196400_80000010_3C007E01_00007C00, .qm = 0x14195400_44003800_7C013C00_BC003C00 }, .{ .qd = 0x7E00FC00_80408010_7E007E00_7E00FC00, .fpscr = 0x00040015, .vpr = 0x00000000 }),
    vec("vcmla.f32 #270 ordinary values and rounding", .{ .hw1 = 0xFDB2, .hw2 = 0x0844, .qd = 0x42C80000_322BCC77_BE800000_3F800000, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000, .qm = 0xC0E00000_3E99999A_3F000000_40400000 }, .{ .qd = 0x42C63333_C1A80000_40B80000_00000000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcmla.f32 #270 overflow, infinities and infinity times zero with a qnan addend", .{ .hw1 = 0xFDB2, .hw2 = 0x0844, .qd = 0xFF800000_7FC00000_3F800000_3F800000, .qn = 0x00000000_7F800000_7149F2CA_7149F2CA, .qm = 0x3F800000_00000000_8DA24260_501502F9 }, .{ .qd = 0xFF800000_7FC00000_FF800000_B29C7F00, .fpscr = 0x00040014, .vpr = 0x00000000 }),
    vec("vcmla.f32 #270 nans, flushed denormals and signed zeros", .{ .hw1 = 0xFDB2, .hw2 = 0x0844, .qd = 0x7F800001_80000020_80000000_00000000, .qn = 0x80000000_1E3CE508_00000010_7FC00001, .qm = 0x7F800000_1E3CE508_7F800001_40000000 }, .{ .qd = 0x7FC00000_7FC00000_80000000_7FC00000, .fpscr = 0x00040081, .vpr = 0x00000000 }),
    vec("vcmla.f32 #270 exact cancellation and zero signs", .{ .hw1 = 0xFDB2, .hw2 = 0x0844, .qd = 0x80000000_3F000000_C1000000_C0C00000, .qn = 0x80000000_3F000000_00000000_40000000, .qm = 0x3E800000_BF800000_40800000_40400000 }, .{ .qd = 0x80000000_3F000000_C1000000_C0C00000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("vcmla.f16 #270 ordinary values, overflow and subnormals", .{ .hw1 = 0xFDA2, .hw2 = 0x0844, .qd = 0x8000FC00_0002FB53_56401419_B4003C00, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .qm = 0x7C000001_211F5CB0_C70034CD_38004200 }, .{ .qd = 0x80027E00_C200FB53_5632CD40_45C00000, .fpscr = 0x00040011, .vpr = 0x00000000 }),
    vec("vcmla.f16 #270 infinities, nans and subnormals", .{ .hw1 = 0xFDA2, .hw2 = 0x0844, .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00, .qn = 0x14196400_80000010_3C007E01_00007C00, .qm = 0x14195400_44003800_7C013C00_BC003C00 }, .{ .qd = 0x7E00FBFF_00008008_C0007E00_7E00FC00, .fpscr = 0x00040011, .vpr = 0x00000000 }),
    vec("vcmla.f32 #0 rounds once, where a separate multiply would lose the low bit", .{ .hw1 = 0xFC32, .hw2 = 0x0844, .qd = 0x7F7FFFFF_BF800000_BF801000_BF801000, .qn = 0x3F800000_3F800800_00000000_3F800800, .qm = 0xBF800800_3F800800_3F800800_3F800800 }, .{ .qd = 0x7F7FFFFF_3A000400_33800000_33800000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcmla.f32 #180 fused near the top of the range", .{ .hw1 = 0xFD32, .hw2 = 0x0844, .qd = 0x7F7FFFFF_BF800000_BF801000_BF801000, .qn = 0x3F800000_3F800800_00000000_3F800800, .qm = 0xBF800800_3F800800_3F800800_3F800800 }, .{ .qd = 0x7F7FFFFF_C0000800_C0001000_C0001000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcmla.f16 #0 with fz16 flushes subnormals", .{ .hw1 = 0xFC22, .hw2 = 0x0844, .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00, .qn = 0x14196400_80000010_3C007E01_00007C00, .qm = 0x14195400_44003800_7C013C00_BC003C00, .fpscr = 0x000C0000 }, .{ .qd = 0x7E005000_00000000_7E007E00_7E007E00, .fpscr = 0x000C0001, .vpr = 0x00000000 }),
    vec("fz, dn and rmode in fpscr are ignored and flags accumulate", .{ .hw1 = 0xFCB2, .hw2 = 0x0844, .qd = 0x42C80000_322BCC77_BE800000_3F800000, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000, .qm = 0xC0E00000_3E99999A_3F000000_40400000, .fpscr = 0x03C40010 }, .{ .qd = 0x42C9CCCD_41A80000_C0C80000_40000000, .fpscr = 0x03C40010, .vpr = 0x00000000 }),
    vec("qn equal to qm squares the pair into the accumulator", .{ .hw1 = 0xFC38, .hw2 = 0x0848, .qd = 0x42C80000_322BCC77_BE800000_3F800000, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000 }, .{ .qd = 0x42C80000_322BCC77_BE800000_3F800000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("q7 from q6 and q5 at f16", .{ .hw1 = 0xFDAC, .hw2 = 0xE84A, .qd = 0x8000FC00_0002FB53_56401419_B4003C00, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .qm = 0x7C000001_211F5CB0_C70034CD_38004200 }, .{ .qd = 0x80027E00_C200FB53_5632CD40_45C00000, .fpscr = 0x00040011, .vpr = 0x00000000 }),
};

const predicated = [_]V{
    vec("vpt mask keeps pair 1", .{ .hw1 = 0xFC32, .hw2 = 0x0844, .qd = 0x7F800001_80000020_80000000_00000000, .qn = 0x80000000_1E3CE508_00000010_7FC00001, .qm = 0x7F800000_1E3CE508_7F800001_40000000, .vpr = 0x0088FF00 }, .{ .qd = 0x7FC00000_00000000_80000000_00000000, .fpscr = 0x00040089, .vpr = 0x0000FF00 }),
    vec("a predicated imaginary half runs the pair but only its own flags count", .{ .hw1 = 0xFCB2, .hw2 = 0x0844, .qd = 0xFF800000_7FC00000_3F800000_3F800000, .qn = 0x00000000_7F800000_7149F2CA_7149F2CA, .qm = 0x3F800000_00000000_8DA24260_501502F9, .vpr = 0x0088F0F0 }, .{ .qd = 0xFF800000_7FC00000_7F800000_3F800000, .fpscr = 0x00040014, .vpr = 0x0000F0F0 }),
    vec("only the real half of each f16 pair predicated", .{ .hw1 = 0xFD22, .hw2 = 0x0844, .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00, .qn = 0x14196400_80000010_3C007E01_00007C00, .qm = 0x14195400_44003800_7C013C00_BC003C00, .vpr = 0x00883333 }, .{ .qd = 0x7C01FC00_00008010_BC007E00_7E00FC00, .fpscr = 0x00040014, .vpr = 0x00003333 }),
    vec("the loop tail on 16-bit lanes stops after lane 2", .{ .hw1 = 0xFDA2, .hw2 = 0x0844, .qd = 0x8000FC00_0002FB53_56401419_B4003C00, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .qm = 0x7C000001_211F5CB0_C70034CD_38004200, .lr = 3, .fpscr = 0x00010000 }, .{ .qd = 0x8000FC00_0002FB53_5640CD40_45C00000, .fpscr = 0x00010010, .vpr = 0x00000000 }),
    vec("eci a0a1 leaves the done beats alone", .{ .hw1 = 0xFC32, .hw2 = 0x0844, .qd = 0xFF800000_7FC00000_3F800000_3F800000, .qn = 0x00000000_7F800000_7149F2CA_7149F2CA, .qm = 0x3F800000_00000000_8DA24260_501502F9, .it = 0x20 }, .{ .qd = 0x7FC00000_7FC00000_3F800000_3F800000, .fpscr = 0x00040001, .vpr = 0x00000000 }),
    vec("eci a0a1a2 runs only beat 3", .{ .hw1 = 0xFCA2, .hw2 = 0x0844, .qd = 0x7C01FBFF_00008008_BC004000_7E00FC00, .qn = 0x14196400_80000010_3C007E01_00007C00, .qm = 0x14195400_44003800_7C013C00_BC003C00, .it = 0x40 }, .{ .qd = 0x7E00FBFF_00008008_BC004000_7E00FC00, .fpscr = 0x00040011, .vpr = 0x00000000 }),
};

const unclaimed = [_]V{
    vec("hw1 bit 0 set is unclaimed", .{ .hw1 = 0xFC33, .hw2 = 0x0844 }, none),
    vec("d set would name q8 and is unclaimed", .{ .hw1 = 0xFC72, .hw2 = 0x0844 }, none),
    vec("hw1 bit 9 set is unclaimed", .{ .hw1 = 0xFE32, .hw2 = 0x0844 }, none),
    vec("hw2 bit 12 set is unclaimed", .{ .hw1 = 0xFC32, .hw2 = 0x1844 }, none),
    vec("n set would name q8 and is unclaimed", .{ .hw1 = 0xFC32, .hw2 = 0x08C4 }, none),
    vec("m set would name q8 and is unclaimed", .{ .hw1 = 0xFC32, .hw2 = 0x0864 }, none),
    vec("hw2 bit 4 set is unclaimed", .{ .hw1 = 0xFC32, .hw2 = 0x0854 }, none),
    vec("hw2 bit 0 set is unclaimed", .{ .hw1 = 0xFC32, .hw2 = 0x0845 }, none),
    vec("hw2[11:8] other than 1000 is unclaimed", .{ .hw1 = 0xFC32, .hw2 = 0x0944 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xFC32, .hw2 = 0x0844, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
