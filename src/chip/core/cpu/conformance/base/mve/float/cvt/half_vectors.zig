//! Conformance vectors for the decode group `mve_float_cvt_half`
//! (RA8EMU-278): VCVTB and VCVTT between F32 and F16 lanes, both ways.
//! Expected values are worked from the Arm ARM (DDI0553) pseudocode:
//! FPConvert under StandardFPSCRValue (round to nearest even, DN and FZ
//! set, AHP and FZ16 kept). Narrowing flushes an F32 denormal with IDC, a
//! NaN becomes the default NaN (IOC if signalling), a tiny inexact result
//! raises UFC and IXC (tininess before rounding), an overflow OFC and IXC;
//! with AHP a NaN becomes a signed zero and an infinity or overflow the
//! largest magnitude, each with IOC only. Widening is exact; with AHP the
//! exponent-31 half patterns are ordinary numbers. Narrowing writes the
//! bottom or top half of each Qd word and keeps the other; widening reads
//! that half of each Qm word. A lane runs when any byte is predicated (VPT,
//! loop tail, EPSR.ECI), bytes merge under the mask, and its flags count
//! only when byte 0 (narrow, or VCVTB widen) or byte 2 (VCVTT widen) is.
//! Qd is written before Qm. Q8 and above, flipped fixed bits, VMAXNMA's
//! bit 7 and the 16-bit space are unclaimed.
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
const group = "mve_float_cvt_half";
pub const none: Out = .{ .claimed = false, .qd = 0, .fpscr = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = conversions ++ modes ++ predicated ++ unclaimed;

const conversions = [_]V{
    vec("vcvtb.f16.f32 ordinary values, max finite and the overflow edge", .{ .hw1 = 0xEE3F, .hw2 = 0x0E03, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x477FF000_477FE000_C0200000_3F800000 }, .{ .qd = 0x11117C00_33337BFF_5555C100_77773C00, .fpscr = 0x00040014, .vpr = 0x00000000 }),
    vec("vcvtb.f16.f32 ties to even and inexact rounding", .{ .hw1 = 0xEE3F, .hw2 = 0x0E03, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xBEAAAAAB_3F801800_3F803000_3F802000 }, .{ .qd = 0x1111B555_33333C01_55553C02_77773C01, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvtb.f16.f32 subnormal results raise ufc only when inexact", .{ .hw1 = 0xEE3F, .hw2 = 0x0E03, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x358637BD_32FFFAE5_33800000_38800000 }, .{ .qd = 0x11110011_33330000_55550001_77770400, .fpscr = 0x00040018, .vpr = 0x00000000 }),
    vec("vcvtb.f16.f32 nans to the default nan, infinity, a flushed denormal", .{ .hw1 = 0xEE3F, .hw2 = 0x0E03, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x00000123_7F800000_FF800001_7FC00123 }, .{ .qd = 0x11110000_33337C00_55557E00_77777E00, .fpscr = 0x00040081, .vpr = 0x00000000 }),
    vec("vcvtb.f16.f32 signed zero, large values, more overflow", .{ .hw1 = 0xEE3F, .hw2 = 0x0E03, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x4808B800_47FFE000_4788B800_80000000 }, .{ .qd = 0x11117C00_33337C00_55557C00_77778000, .fpscr = 0x00040014, .vpr = 0x00000000 }),
    vec("vcvtb.f32.f16 normals, max, subnormals, infinities", .{ .hw1 = 0xFE3F, .hw2 = 0x0E03, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xFC007C00_840003FF_00017BFF_C1003C00 }, .{ .qd = 0x7F800000_387FC000_477FE000_3F800000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("vcvtb.f32.f16 nans and zeros", .{ .hw1 = 0xFE3F, .hw2 = 0x0E03, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xFFFF7FFF_35550000_8000FE00_7C017E01 }, .{ .qd = 0x7FC00000_00000000_7FC00000_7FC00000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("vcvtt.f16.f32 ordinary values, max finite and the overflow edge", .{ .hw1 = 0xEE3F, .hw2 = 0x1E03, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x477FF000_477FE000_C0200000_3F800000 }, .{ .qd = 0x7C002222_7BFF4444_C1006666_3C008888, .fpscr = 0x00040014, .vpr = 0x00000000 }),
    vec("vcvtt.f16.f32 ties to even and inexact rounding", .{ .hw1 = 0xEE3F, .hw2 = 0x1E03, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xBEAAAAAB_3F801800_3F803000_3F802000 }, .{ .qd = 0xB5552222_3C014444_3C026666_3C018888, .fpscr = 0x00040010, .vpr = 0x00000000 }),
    vec("vcvtt.f16.f32 subnormal results raise ufc only when inexact", .{ .hw1 = 0xEE3F, .hw2 = 0x1E03, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x358637BD_32FFFAE5_33800000_38800000 }, .{ .qd = 0x00112222_00004444_00016666_04008888, .fpscr = 0x00040018, .vpr = 0x00000000 }),
    vec("vcvtt.f16.f32 nans to the default nan, infinity, a flushed denormal", .{ .hw1 = 0xEE3F, .hw2 = 0x1E03, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x00000123_7F800000_FF800001_7FC00123 }, .{ .qd = 0x00002222_7C004444_7E006666_7E008888, .fpscr = 0x00040081, .vpr = 0x00000000 }),
    vec("vcvtt.f16.f32 signed zero, large values, more overflow", .{ .hw1 = 0xEE3F, .hw2 = 0x1E03, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x4808B800_47FFE000_4788B800_80000000 }, .{ .qd = 0x7C002222_7C004444_7C006666_80008888, .fpscr = 0x00040014, .vpr = 0x00000000 }),
    vec("vcvtt.f32.f16 normals, max, subnormals, infinities", .{ .hw1 = 0xFE3F, .hw2 = 0x1E03, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xFC007C00_840003FF_00017BFF_C1003C00 }, .{ .qd = 0xFF800000_B8800000_33800000_C0200000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("vcvtt.f32.f16 nans and zeros", .{ .hw1 = 0xFE3F, .hw2 = 0x1E03, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xFFFF7FFF_35550000_8000FE00_7C017E01 }, .{ .qd = 0x7FC00000_3EAAA000_80000000_7FC00000, .fpscr = 0x00040001, .vpr = 0x00000000 }),
};

const modes = [_]V{
    vec("vcvtb.f16.f32 with ahp: nan to signed zero and infinity to max with ioc", .{ .hw1 = 0xEE3F, .hw2 = 0x0E03, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x00000123_7F800000_FF800001_7FC00123, .fpscr = 0x04040000 }, .{ .qd = 0x11110000_33337FFF_55558000_77770000, .fpscr = 0x04040081, .vpr = 0x00000000 }),
    vec("vcvtt.f16.f32 with ahp: exponent 31 values and the ahp overflow", .{ .hw1 = 0xEE3F, .hw2 = 0x1E03, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x4808B800_47FFE000_4788B800_80000000, .fpscr = 0x04040000 }, .{ .qd = 0x7FFF2222_7FFF4444_7C466666_80008888, .fpscr = 0x04040011, .vpr = 0x00000000 }),
    vec("vcvtb.f32.f16 with ahp: exponent 31 is an ordinary binade", .{ .hw1 = 0xFE3F, .hw2 = 0x0E03, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xFC007C00_840003FF_00017BFF_C1003C00, .fpscr = 0x04040000 }, .{ .qd = 0x47800000_387FC000_477FE000_3F800000, .fpscr = 0x04040000, .vpr = 0x00000000 }),
    vec("vcvtt.f32.f16 with ahp: nan patterns read as numbers", .{ .hw1 = 0xFE3F, .hw2 = 0x1E03, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xFFFF7FFF_35550000_8000FE00_7C017E01, .fpscr = 0x04040000 }, .{ .qd = 0xC7FFE000_3EAAA000_80000000_47802000, .fpscr = 0x04040000, .vpr = 0x00000000 }),
    vec("fz, dn and rmode in fpscr are ignored and flags accumulate", .{ .hw1 = 0xEE3F, .hw2 = 0x0E03, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xBEAAAAAB_3F801800_3F803000_3F802000, .fpscr = 0x03C40004 }, .{ .qd = 0x1111B555_33333C01_55553C02_77773C01, .fpscr = 0x03C40014, .vpr = 0x00000000 }),
    vec("qd equal to qm narrows in place", .{ .hw1 = 0xEE3F, .hw2 = 0x7E07, .qm = 0x477FF000_477FE000_C0200000_3F800000 }, .{ .qd = 0x7C00F000_7BFFE000_C1000000_3C000000, .fpscr = 0x00040014, .vpr = 0x00000000 }),
    vec("q7 from q6 widens", .{ .hw1 = 0xFE3F, .hw2 = 0xEE0D, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xFC007C00_840003FF_00017BFF_C1003C00 }, .{ .qd = 0x7F800000_387FC000_477FE000_3F800000, .fpscr = 0x00040000, .vpr = 0x00000000 }),
};

const predicated = [_]V{
    vec("vpt mask keeps lanes 1 and 3 of a narrow", .{ .hw1 = 0xEE3F, .hw2 = 0x0E03, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x00000123_7F800000_FF800001_7FC00123, .vpr = 0x00880F0F }, .{ .qd = 0x11112222_33337C00_55556666_77777E00, .fpscr = 0x00040000, .vpr = 0x00000F0F }),
    vec("vcvtt narrow with only the upper half bytes predicated drops the lane flags", .{ .hw1 = 0xEE3F, .hw2 = 0x1E03, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x00000123_7F800000_FF800001_7FC00123, .vpr = 0x0088CCCC }, .{ .qd = 0x00002222_7C004444_7E006666_7E008888, .fpscr = 0x00040000, .vpr = 0x0000CCCC }),
    vec("vcvtt widen counts flags from byte 2", .{ .hw1 = 0xFE3F, .hw2 = 0x1E03, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xFFFF7FFF_35550000_8000FE00_7C017E01, .vpr = 0x00884444 }, .{ .qd = 0x11C02222_33AA4444_55006666_77C08888, .fpscr = 0x00040001, .vpr = 0x00004444 }),
    vec("vcvtb widen with byte 0 off drops the lane flags", .{ .hw1 = 0xFE3F, .hw2 = 0x0E03, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xFFFF7FFF_35550000_8000FE00_7C017E01, .vpr = 0x0088EEEE }, .{ .qd = 0x7FC00022_00000044_7FC00066_7FC00088, .fpscr = 0x00040000, .vpr = 0x0000EEEE }),
    vec("the loop tail stops after lane 1", .{ .hw1 = 0xEE3F, .hw2 = 0x0E03, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x00000123_7F800000_FF800001_7FC00123, .lr = 2, .fpscr = 0x00020000 }, .{ .qd = 0x11112222_33334444_55557E00_77777E00, .fpscr = 0x00020001, .vpr = 0x00000000 }),
    vec("eci a0a1 leaves the done beats alone", .{ .hw1 = 0xFE3F, .hw2 = 0x1E03, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0xFFFF7FFF_35550000_8000FE00_7C017E01, .it = 0x20 }, .{ .qd = 0x7FC00000_3EAAA000_55556666_77778888, .fpscr = 0x00040000, .vpr = 0x00000000 }),
    vec("eci a0a1a2 runs only beat 3", .{ .hw1 = 0xEE3F, .hw2 = 0x0E03, .qd = 0x11112222_33334444_55556666_77778888, .qm = 0x477FF000_477FE000_C0200000_3F800000, .it = 0x40 }, .{ .qd = 0x11117C00_33334444_55556666_77778888, .fpscr = 0x00040014, .vpr = 0x00000000 }),
};

const unclaimed = [_]V{
    vec("hw2 bit 7 set is vmaxnma, not this group", .{ .hw1 = 0xEE3F, .hw2 = 0x0E83 }, none),
    vec("hw2 bit 0 clear is unclaimed", .{ .hw1 = 0xEE3F, .hw2 = 0x0E02 }, none),
    vec("d set would name q8 and is unclaimed", .{ .hw1 = 0xEE7F, .hw2 = 0x0E03 }, none),
    vec("m set would name q8 and is unclaimed", .{ .hw1 = 0xEE3F, .hw2 = 0x0E23 }, none),
    vec("hw1 low nibble other than 1111 is unclaimed", .{ .hw1 = 0xEE3E, .hw2 = 0x0E03 }, none),
    vec("hw1[5:4] other than 11 is unclaimed", .{ .hw1 = 0xEE2F, .hw2 = 0x0E03 }, none),
    vec("hw2[11:8] other than 1110 is unclaimed", .{ .hw1 = 0xEE3F, .hw2 = 0x0F03 }, none),
    vec("hw2 bit 4 set is unclaimed", .{ .hw1 = 0xEE3F, .hw2 = 0x0E13 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEE3F, .hw2 = 0x0E03, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
