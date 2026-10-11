//! Conformance vectors for the decode group `mve_float_vcadd`
//! (RA8EMU-278): floating-point VCADD on F32 and F16 lane pairs, rotation
//! 90 and 270. Expected values are worked from the Arm ARM (DDI0553)
//! pseudocode: rotation 90 gives (n.re - m.im, n.im + m.re) and 270 the
//! other way, each lane one FPAdd or FPSub under StandardFPSCRValue (round
//! to nearest even, DN and FZ set, FZ16 kept). An F32 denormal operand
//! reads as zero with IDC and an F32 result below the normal range is
//! flushed to zero with UFC; with FZ16 an F16 subnormal operand reads as
//! zero with no flag. NaNs give the default NaN (IOC if signalling), so
//! does +inf - inf; overflow gives infinity with OFC and IXC. A lane runs
//! when any byte is predicated (VPT, loop tail, EPSR.ECI), bytes merge
//! under the mask, and its flags count only when its first byte is. Qd,
//! Qn and Qm are written in that order; Qd never equals Qm here (that is
//! UNPREDICTABLE at F32). Q8 and above, flipped fixed bits and the 16-bit
//! space are unclaimed.
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
const group = "mve_float_vcadd";
pub const none: Out = .{ .claimed = false, .qd = 0, .fpscr = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = rotations ++ predicated ++ unclaimed;

const rotations = [_]V{
    vec("vcadd.f32 #90 ordinary values and a rounded sum", .{ .hw1 = 0xFC92, .hw2 = 0x0844, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x3E800000_C0600000_40000000_3F800000, .qm = 0x3F800000_7149F2CA_C0800000_3F000000 }, .{ .qd = 0x7149F2CA_C0900000_40200000_40A00000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcadd.f32 #90 overflow, a flushed denormal and an exact zero", .{ .hw1 = 0xFC92, .hw2 = 0x0844, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x00000001_3F800000_FF61B1E6_7F61B1E6, .qm = 0x00000000_00400000_7F61B1E6_7F61B1E6 }, .{ .qd = 0x00000000_3F800000_00000000_00000000, .fpscr = 0x00040080, .vpr = 0x00000000 }),
    vec("vcadd.f32 #90 infinities, nans and signed zeros", .{ .hw1 = 0xFC92, .hw2 = 0x0844, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x80000000_7FC00001_7F800000_7F800000, .qm = 0x7F800001_00000000_7F800000_7F800000 }, .{ .qd = 0x00000000_7FC00000_7F800000_7FC00000, .fpscr = 0x00040001, .vpr = 0x00000000 }),
    vec("vcadd.f32 #90 a tiny flushed result and big-number rounding", .{ .hw1 = 0xFC92, .hw2 = 0x0844, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x3F800000_4B800000_80000000_00A355E6, .qm = 0x3F800000_00000000_0082AB1E_00000000 }, .{ .qd = 0x3F800000_4B7FFFFF_00000000_00000000, .fpscr = 0x00040008, .vpr = 0x00000000 }),
    vec("vcadd.f16 #90 ordinary values, overflow and rounding", .{ .hw1 = 0xFC82, .hw2 = 0x0844, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0xBC007BFF_14195640_3400C300_40003C00, .qm = 0x5000FBFF_AE662E66_3C003C00_C4003800 }, .{ .qd = 0xFBFF7BFE_2E765642_3D00C480_41004500, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcadd.f16 #90 infinities, nans, subnormals and zeros", .{ .hw1 = 0xFC82, .hw2 = 0x0844, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x80006800_80000010_00017E01_7C007C00, .qm = 0x00003C00_00040008_3C007C01_7C007C00 }, .{ .qd = 0x3C006800_0008000C_7E007E00_7C007E00, .fpscr = 0x00040001, .vpr = 0x00000000 }),
    vec("vcadd.f32 #270 ordinary values and a rounded sum", .{ .hw1 = 0xFD92, .hw2 = 0x0844, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x3E800000_C0600000_40000000_3F800000, .qm = 0x3F800000_7149F2CA_C0800000_3F000000 }, .{ .qd = 0xF149F2CA_C0200000_3FC00000_C0400000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcadd.f32 #270 overflow, a flushed denormal and an exact zero", .{ .hw1 = 0xFD92, .hw2 = 0x0844, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x00000001_3F800000_FF61B1E6_7F61B1E6, .qm = 0x00000000_00400000_7F61B1E6_7F61B1E6 }, .{ .qd = 0x00000000_3F800000_FF800000_7F800000, .fpscr = 0x00040094, .vpr = 0x00000000 }),
    vec("vcadd.f32 #270 infinities, nans and signed zeros", .{ .hw1 = 0xFD92, .hw2 = 0x0844, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x80000000_7FC00001_7F800000_7F800000, .qm = 0x7F800001_00000000_7F800000_7F800000 }, .{ .qd = 0x80000000_7FC00000_7FC00000_7F800000, .fpscr = 0x00040001, .vpr = 0x00000000 }),
    vec("vcadd.f32 #270 a tiny flushed result and big-number rounding", .{ .hw1 = 0xFD92, .hw2 = 0x0844, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x3F800000_4B800000_80000000_00A355E6, .qm = 0x3F800000_00000000_0082AB1E_00000000 }, .{ .qd = 0x3F800000_4B800000_80000000_01130082, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcadd.f16 #270 ordinary values, overflow and rounding", .{ .hw1 = 0xFD82, .hw2 = 0x0844, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0xBC007BFF_14195640_3400C300_40003C00, .qm = 0x5000FBFF_AE662E66_3C003C00_C4003800 }, .{ .qd = 0x7BFF7C00_AE56563E_BA00C100_3E00C200, .fpscr = 0x00040014, .vpr = 0x00000000 }),
    vec("vcadd.f16 #270 infinities, nans, subnormals and zeros", .{ .hw1 = 0xFD82, .hw2 = 0x0844, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x80006800_80000010_00017E01_7C007C00, .qm = 0x00003C00_00040008_3C007C01_7C007C00 }, .{ .qd = 0xBC006800_80080014_7E007E00_7E007C00, .fpscr = 0x00040001, .vpr = 0x00000000 }),
    vec("vcadd.f16 #90 with fz16 flushes subnormals without idc", .{ .hw1 = 0xFC82, .hw2 = 0x0844, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x80006800_80000010_00017E01_7C007C00, .qm = 0x00003C00_00040008_3C007C01_7C007C00, .fpscr = 0x000C0000 }, .{ .qd = 0x3C006800_00000000_7E007E00_7C007E00, .fpscr = 0x000C0001, .vpr = 0x00000000 }),
    vec("fz, dn and rmode in fpscr are ignored and flags accumulate", .{ .hw1 = 0xFD92, .hw2 = 0x0844, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x3E800000_C0600000_40000000_3F800000, .qm = 0x3F800000_7149F2CA_C0800000_3F000000, .fpscr = 0x03C40010 }, .{ .qd = 0xF149F2CA_C0200000_3FC00000_C0400000, .fpscr = 0x03C40010, .vpr = 0x00000000 }),
    vec("qd equal to qn adds in place", .{ .hw1 = 0xFC96, .hw2 = 0x684A, .qn = 0x3E800000_C0600000_40000000_3F800000, .qm = 0x3F800000_7149F2CA_C0800000_3F000000 }, .{ .qd = 0x7149F2CA_C0900000_40200000_40A00000, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("q7 from q6 and q5 at f16", .{ .hw1 = 0xFD8C, .hw2 = 0xE84A, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0xBC007BFF_14195640_3400C300_40003C00, .qm = 0x5000FBFF_AE662E66_3C003C00_C4003800 }, .{ .qd = 0x7BFF7C00_AE56563E_BA00C100_3E00C200, .fpscr = 0x00040014, .vpr = 0x00000000 }),
};

const predicated = [_]V{
    vec("vpt mask keeps lanes 1 and 3", .{ .hw1 = 0xFC92, .hw2 = 0x0844, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x80000000_7FC00001_7F800000_7F800000, .qm = 0x7F800001_00000000_7F800000_7F800000, .vpr = 0x0088F0F0 }, .{ .qd = 0x00000000_33334444_7F800000_77778888, .fpscr = 0x00040000, .vpr = 0x0000F0F0 }),
    vec("a lane with byte 0 off is written but its flags drop", .{ .hw1 = 0xFD92, .hw2 = 0x0844, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x00000001_3F800000_FF61B1E6_7F61B1E6, .qm = 0x00000000_00400000_7F61B1E6_7F61B1E6, .vpr = 0x0088EEEE }, .{ .qd = 0x00000022_3F800044_FF800066_7F800088, .fpscr = 0x00040000, .vpr = 0x0000EEEE }),
    vec("f16 lanes count flags from their low byte", .{ .hw1 = 0xFC82, .hw2 = 0x0844, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x80006800_80000010_00017E01_7C007C00, .qm = 0x00003C00_00040008_3C007C01_7C007C00, .vpr = 0x0088AAAA }, .{ .qd = 0x3C116822_00330044_7E557E66_7C777E88, .fpscr = 0x00040000, .vpr = 0x0000AAAA }),
    vec("the loop tail on 16-bit lanes stops after lane 2", .{ .hw1 = 0xFD82, .hw2 = 0x0844, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0xBC007BFF_14195640_3400C300_40003C00, .qm = 0x5000FBFF_AE662E66_3C003C00_C4003800, .lr = 3, .fpscr = 0x00010000 }, .{ .qd = 0x11112222_33334444_5555C100_3E00C200, .fpscr = 0x00010000, .vpr = 0x00000000 }),
    vec("eci a0a1 leaves the done beats alone", .{ .hw1 = 0xFC92, .hw2 = 0x0844, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x00000001_3F800000_FF61B1E6_7F61B1E6, .qm = 0x00000000_00400000_7F61B1E6_7F61B1E6, .it = 0x20 }, .{ .qd = 0x00000000_3F800000_55556666_77778888, .fpscr = 0x00040080, .vpr = 0x00000000 }),
    vec("eci a0a1a2 runs only beat 3", .{ .hw1 = 0xFC82, .hw2 = 0x0844, .qd = 0x11112222_33334444_55556666_77778888, .qn = 0x80006800_80000010_00017E01_7C007C00, .qm = 0x00003C00_00040008_3C007C01_7C007C00, .it = 0x40 }, .{ .qd = 0x3C006800_33334444_55556666_77778888, .fpscr = 0x00040000, .vpr = 0x00000000 }),
};

const unclaimed = [_]V{
    vec("hw1 bit 0 set is unclaimed", .{ .hw1 = 0xFC93, .hw2 = 0x0844 }, none),
    vec("d set would name q8 and is unclaimed", .{ .hw1 = 0xFCD2, .hw2 = 0x0844 }, none),
    vec("hw1 bit 5 set is unclaimed", .{ .hw1 = 0xFCB2, .hw2 = 0x0844 }, none),
    vec("hw1 bit 7 clear is unclaimed", .{ .hw1 = 0xFC12, .hw2 = 0x0844 }, none),
    vec("hw1 bit 9 set is unclaimed", .{ .hw1 = 0xFE92, .hw2 = 0x0844 }, none),
    vec("n set would name q8 and is unclaimed", .{ .hw1 = 0xFC92, .hw2 = 0x08C4 }, none),
    vec("m set would name q8 and is unclaimed", .{ .hw1 = 0xFC92, .hw2 = 0x0864 }, none),
    vec("hw2 bit 0 set is unclaimed", .{ .hw1 = 0xFC92, .hw2 = 0x0845 }, none),
    vec("hw2 bit 6 clear is unclaimed", .{ .hw1 = 0xFC92, .hw2 = 0x0804 }, none),
    vec("hw2 bit 12 set is unclaimed", .{ .hw1 = 0xFC92, .hw2 = 0x1844 }, none),
    vec("hw2[11:8] other than 1000 is unclaimed", .{ .hw1 = 0xFC92, .hw2 = 0x0944 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xFC92, .hw2 = 0x0844, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
