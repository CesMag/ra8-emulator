//! Conformance vectors for the decode group `mve_float_vcmul`
//! (RA8EMU-278): VCMUL on F32 and F16 lane pairs, rotations 0, 90, 180 and
//! 270. Expected values are worked from the Arm ARM (DDI0553) pseudocode:
//! (re, im) is (n.re*m.re, n.re*m.im) at 0, (n.im*-m.im, n.im*m.re) at
//! 90, (n.re*-m.re, n.re*-m.im) at 180 and (n.im*m.im, n.im*-m.re) at 270,
//! each one FPMul under StandardFPSCRValue (round to nearest even, DN and
//! FZ set, FZ16 kept). An F32 denormal operand reads as zero with IDC and a
//! tiny F32 product flushes to zero with UFC; with FZ16 an F16 subnormal
//! operand reads as zero with no flag. NaNs and infinity times zero give
//! the default NaN (IOC if signalling or invalid); overflow gives infinity
//! with OFC and IXC. A pair runs when any of its bytes is predicated (VPT,
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
const group = "mve_float_vcmul";
pub const none: Out = .{ .claimed = false, .qd = 0, .fpscr = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = rotations ++ predicated ++ unclaimed;

const rotations = [_]V{
    vec("vcmul.f32 #0 ordinary values and rounding", .{ .hw1 = 0xFE32, .hw2 = 0x0E04, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000, .qm = 0xC0E00000_3E99999A_3F000000_40400000 }, .{ .qd = 0xBF333333_3CF5C290_3F400000_40900000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcmul.f32 #0 overflow, underflow and infinity times zero", .{ .hw1 = 0xFE32, .hw2 = 0x0E04, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x00000000_7F800000_7149F2CA_7149F2CA, .qm = 0x3F800000_00000000_8DA24260_501502F9 }, .{ .qd = 0x7F800000_7FC00000_BF800000_7F800000, .fpscr = 0x00040015, .vpr = 0x00000000 }),
    vec("vcmul.f32 #0 nans, a flushed denormal and signed zeros", .{ .hw1 = 0xFE32, .hw2 = 0x0E04, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x80000000_1E3CE508_00000010_7FC00001, .qm = 0x7F800000_1E3CE508_7F800001_40000000 }, .{ .qd = 0x7F800000_00000000_7FC00000_7FC00000, .fpscr = 0x00040009, .vpr = 0x00000000 }),
    vec("vcmul.f16 #0 ordinary values, overflow and a subnormal", .{ .hw1 = 0xEE32, .hw2 = 0x0E04, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .qm = 0x7C000001_211F5CB0_C70034CD_38004200 }, .{ .qd = 0xFC008000_42007C00_B99927AE_3A004480, .fpscr = 0x0004001C, .vpr = 0x00000000 }),
    vec("vcmul.f16 #0 infinities, nans and subnormals", .{ .hw1 = 0xEE32, .hw2 = 0x0E04, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x14196400_80000010_3C007E01_00007C00, .qm = 0x14195400_44003800_7C013C00_BC003C00 }, .{ .qd = 0x3C197C00_00400008_7E007E00_FC007C00, .fpscr = 0x00040015, .vpr = 0x00000000 }),
    vec("vcmul.f32 #90 ordinary values and rounding", .{ .hw1 = 0xFE32, .hw2 = 0x0E05, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000, .qm = 0xC0E00000_3E99999A_3F000000_40400000 }, .{ .qd = 0x3F666667_41A80000_C0C00000_3F800000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("vcmul.f32 #90 overflow, underflow and infinity times zero", .{ .hw1 = 0xFE32, .hw2 = 0x0E05, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x00000000_7F800000_7149F2CA_7149F2CA, .qm = 0x3F800000_00000000_8DA24260_501502F9 }, .{ .qd = 0x00000000_80000000_7F800000_3F800000, .fpscr = 0x00040014, .vpr = 0x00000000 }),
    vec("vcmul.f32 #90 nans, a flushed denormal and signed zeros", .{ .hw1 = 0xFE32, .hw2 = 0x0E05, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x80000000_1E3CE508_00000010_7FC00001, .qm = 0x7F800000_1E3CE508_7F800001_40000000 }, .{ .qd = 0x80000000_7FC00000_00000000_7FC00000, .fpscr = 0x00040081, .vpr = 0x00000000 }),
    vec("vcmul.f16 #90 ordinary values, overflow and a subnormal", .{ .hw1 = 0xEE32, .hw2 = 0x0E05, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .qm = 0x7C000001_211F5CB0_C70034CD_38004200 }, .{ .qd = 0x0002FC00_4200868E_3B344D40_C6003C00, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcmul.f16 #90 infinities, nans and subnormals", .{ .hw1 = 0xEE32, .hw2 = 0x0E05, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x14196400_80000010_3C007E01_00007C00, .qm = 0x14195400_44003800_7C013C00_BC003C00 }, .{ .qd = 0x2C198011_80000000_3C007E00_00000000, .fpscr = 0x00040019, .vpr = 0x00000000 }),
    vec("vcmul.f32 #180 ordinary values and rounding", .{ .hw1 = 0xFE32, .hw2 = 0x1E04, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000, .qm = 0xC0E00000_3E99999A_3F000000_40400000 }, .{ .qd = 0x3F333333_BCF5C290_BF400000_C0900000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcmul.f32 #180 overflow, underflow and infinity times zero", .{ .hw1 = 0xFE32, .hw2 = 0x1E04, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x00000000_7F800000_7149F2CA_7149F2CA, .qm = 0x3F800000_00000000_8DA24260_501502F9 }, .{ .qd = 0xFF800000_7FC00000_3F800000_FF800000, .fpscr = 0x00040015, .vpr = 0x00000000 }),
    vec("vcmul.f32 #180 nans, a flushed denormal and signed zeros", .{ .hw1 = 0xFE32, .hw2 = 0x1E04, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x80000000_1E3CE508_00000010_7FC00001, .qm = 0x7F800000_1E3CE508_7F800001_40000000 }, .{ .qd = 0xFF800000_80000000_7FC00000_7FC00000, .fpscr = 0x00040009, .vpr = 0x00000000 }),
    vec("vcmul.f16 #180 ordinary values, overflow and a subnormal", .{ .hw1 = 0xEE32, .hw2 = 0x1E04, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .qm = 0x7C000001_211F5CB0_C70034CD_38004200 }, .{ .qd = 0x7C000000_C200FC00_3999A7AE_BA00C480, .fpscr = 0x0004001C, .vpr = 0x00000000 }),
    vec("vcmul.f16 #180 infinities, nans and subnormals", .{ .hw1 = 0xEE32, .hw2 = 0x1E04, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x14196400_80000010_3C007E01_00007C00, .qm = 0x14195400_44003800_7C013C00_BC003C00 }, .{ .qd = 0xBC19FC00_80408008_7E007E00_7C00FC00, .fpscr = 0x00040015, .vpr = 0x00000000 }),
    vec("vcmul.f32 #270 ordinary values and rounding", .{ .hw1 = 0xFE32, .hw2 = 0x1E05, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000, .qm = 0xC0E00000_3E99999A_3F000000_40400000 }, .{ .qd = 0xBF666667_C1A80000_40C00000_BF800000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("vcmul.f32 #270 overflow, underflow and infinity times zero", .{ .hw1 = 0xFE32, .hw2 = 0x1E05, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x00000000_7F800000_7149F2CA_7149F2CA, .qm = 0x3F800000_00000000_8DA24260_501502F9 }, .{ .qd = 0x80000000_00000000_FF800000_BF800000, .fpscr = 0x00040014, .vpr = 0x00000000 }),
    vec("vcmul.f32 #270 nans, a flushed denormal and signed zeros", .{ .hw1 = 0xFE32, .hw2 = 0x1E05, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x80000000_1E3CE508_00000010_7FC00001, .qm = 0x7F800000_1E3CE508_7F800001_40000000 }, .{ .qd = 0x00000000_7FC00000_80000000_7FC00000, .fpscr = 0x00040081, .vpr = 0x00000000 }),
    vec("vcmul.f16 #270 ordinary values, overflow and a subnormal", .{ .hw1 = 0xEE32, .hw2 = 0x1E05, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .qm = 0x7C000001_211F5CB0_C70034CD_38004200 }, .{ .qd = 0x80027C00_C200068E_BB34CD40_4600BC00, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcmul.f16 #270 infinities, nans and subnormals", .{ .hw1 = 0xEE32, .hw2 = 0x1E05, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x14196400_80000010_3C007E01_00007C00, .qm = 0x14195400_44003800_7C013C00_BC003C00 }, .{ .qd = 0xAC190011_00008000_BC007E00_80008000, .fpscr = 0x00040019, .vpr = 0x00000000 }),
    vec("vcmul.f16 #0 with fz16 flushes subnormals", .{ .hw1 = 0xEE32, .hw2 = 0x0E04, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x14196400_80000010_3C007E01_00007C00, .qm = 0x14195400_44003800_7C013C00_BC003C00, .fpscr = 0x000C0000 }, .{ .qd = 0x3C197C00_00000000_7E007E00_FC007C00, .fpscr = 0x000C0015, .vpr = 0x00000000 }),
    vec("fz, dn and rmode in fpscr are ignored and flags accumulate", .{ .hw1 = 0xFE32, .hw2 = 0x0E05, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000, .qm = 0xC0E00000_3E99999A_3F000000_40400000, .fpscr = 0x03C40010 }, .{ .qd = 0x3F666667_41A80000_C0C00000_3F800000, .fpscr = 0x03C40010, .vpr = 0x00000000 }),
    vec("qn equal to qm squares the pair", .{ .hw1 = 0xFE38, .hw2 = 0x0E08, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000 }, .{ .qd = 0x00000000_00000000_00000000_00000000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("q7 from q6 and q5 at f16", .{ .hw1 = 0xEE3C, .hw2 = 0xFE0B, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .qm = 0x7C000001_211F5CB0_C70034CD_38004200 }, .{ .qd = 0x80027C00_C200068E_BB34CD40_4600BC00, .fpscr = 0x00040010, .vpr = 0x00000000 }),
};

const predicated = [_]V{
    vec("vpt mask keeps pair 1", .{ .hw1 = 0xFE32, .hw2 = 0x0E04, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x80000000_1E3CE508_00000010_7FC00001, .qm = 0x7F800000_1E3CE508_7F800001_40000000, .vpr = 0x0088FF00 }, .{ .qd = 0x7F800000_00000000_55556666_77778888, .fpscr = 0x00040008, .vpr = 0x0000FF00 }),
    vec("a predicated imaginary half runs the pair but only its own flags count", .{ .hw1 = 0xFE32, .hw2 = 0x0E05, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x80000000_1E3CE508_00000010_7FC00001, .qm = 0x7F800000_1E3CE508_7F800001_40000000, .vpr = 0x0088F0F0 }, .{ .qd = 0x80000000_33334444_00000000_77778888, .fpscr = 0x00040080, .vpr = 0x0000F0F0 }),
    vec("only the real half of each f16 pair predicated", .{ .hw1 = 0xEE32, .hw2 = 0x1E04, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x14196400_80000010_3C007E01_00007C00, .qm = 0x14195400_44003800_7C013C00_BC003C00, .vpr = 0x00883333 }, .{ .qd = 0x1111FC00_33338008_55557E00_7777FC00, .fpscr = 0x00040014, .vpr = 0x00003333 }),
    vec("the loop tail on 16-bit lanes stops after lane 2", .{ .hw1 = 0xEE32, .hw2 = 0x1E05, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x4000B800_211F5CB0_42002E66_C0003E00, .qm = 0x7C000001_211F5CB0_C70034CD_38004200, .lr = 3, .fpscr = 0x00010000 }, .{ .qd = 0x11112222_33334444_5555CD40_4600BC00, .fpscr = 0x00010000, .vpr = 0x00000000 }),
    vec("eci a0a1 leaves the done beats alone", .{ .hw1 = 0xFE32, .hw2 = 0x0E04, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x00000000_7F800000_7149F2CA_7149F2CA, .qm = 0x3F800000_00000000_8DA24260_501502F9, .it = 0x20 }, .{ .qd = 0x7F800000_7FC00000_55556666_77778888, .fpscr = 0x00040001, .vpr = 0x00000000 }),
    vec("eci a0a1a2 runs only beat 3", .{ .hw1 = 0xEE32, .hw2 = 0x0E05, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x14196400_80000010_3C007E01_00007C00, .qm = 0x14195400_44003800_7C013C00_BC003C00, .it = 0x40 }, .{ .qd = 0x2C198011_33334444_55556666_77778888, .fpscr = 0x00040018, .vpr = 0x00000000 }),
};

const unclaimed = [_]V{
    vec("hw1 bit 0 set is unclaimed", .{ .hw1 = 0xFE33, .hw2 = 0x0E04 }, none),
    vec("d set would name q8 and is unclaimed", .{ .hw1 = 0xFE72, .hw2 = 0x0E04 }, none),
    vec("hw1 bit 5 clear is unclaimed", .{ .hw1 = 0xFE12, .hw2 = 0x0E04 }, none),
    vec("hw1 bit 8 set is unclaimed", .{ .hw1 = 0xFF32, .hw2 = 0x0E04 }, none),
    vec("n set would name q8 and is unclaimed", .{ .hw1 = 0xFE32, .hw2 = 0x0E84 }, none),
    vec("m set would name q8 and is unclaimed", .{ .hw1 = 0xFE32, .hw2 = 0x0E24 }, none),
    vec("hw2 bit 4 set is unclaimed", .{ .hw1 = 0xFE32, .hw2 = 0x0E14 }, none),
    vec("hw2 bit 6 set is unclaimed", .{ .hw1 = 0xFE32, .hw2 = 0x0E44 }, none),
    vec("hw2[11:8] other than 1110 is unclaimed", .{ .hw1 = 0xFE32, .hw2 = 0x0F04 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xFE32, .hw2 = 0x0E04, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
