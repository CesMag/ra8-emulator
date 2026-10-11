//! Conformance vectors for the decode group `mve_float_unary` (RA8EMU-278):
//! VABS and VNEG on F32 and F16 lanes. Expected values are worked from the
//! Arm ARM (DDI0553) pseudocode, FPAbs and FPNeg: only the sign bit of each
//! element changes, so NaNs (signalling ones included), infinities and
//! denormals pass through with no flush, no default NaN and no FPSCR
//! flags. The result merges byte by byte under the mask (VPT, loop tail,
//! EPSR.ECI). Qd then Qm is written. Sizes 00 and 11, D or M set, flipped
//! fixed bits and the 16-bit space are left unclaimed.
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
const group = "mve_float_unary";
pub const none: Out = .{ .claimed = false, .qd = 0, .fpscr = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = forms ++ predicated ++ unclaimed;

const forms = [_]V{
    vec("vabs.f32 negatives, nans and -0", .{ .hw1 = 0xFFB9, .hw2 = 0x0744, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0x80000000_FF800001_7FC00001_BF800000 }, .{ .qd = 0x00000000_7F800001_7FC00001_3F800000, .fpscr = 0x00040000 }),
    vec("vabs.f32 denormals and infinities, no flush", .{ .hw1 = 0xFFB9, .hw2 = 0x0744, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0x3F800000_7F800000_807FFFFF_00000001 }, .{ .qd = 0x3F800000_7F800000_007FFFFF_00000001, .fpscr = 0x00040000 }),
    vec("vabs.f16 every lane kind", .{ .hw1 = 0xFFB5, .hw2 = 0x0744, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0x3C007C00_83FF0001_8000FC01_7E01BC00 }, .{ .qd = 0x3C007C00_03FF0001_00007C01_7E013C00, .fpscr = 0x00040000 }),
    vec("vabs.f32 qd = qm", .{ .hw1 = 0xFFB9, .hw2 = 0xA74A, .qm = 0x80000000_FF800001_7FC00001_BF800000 }, .{ .qd = 0x00000000_7F800001_7FC00001_3F800000, .fpscr = 0x00040000 }),
    vec("vabs.f16 leaves fpscr flags and modes alone", .{ .hw1 = 0xFFB5, .hw2 = 0xE742, .qm = 0x3C007C00_83FF0001_8000FC01_7E01BC00, .fpscr = 0x0304009F }, .{ .qd = 0x3C007C00_03FF0001_00007C01_7E013C00, .fpscr = 0x0304009F }),
    vec("vneg.f32 negatives, nans and -0", .{ .hw1 = 0xFFB9, .hw2 = 0x07C4, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0x80000000_FF800001_7FC00001_BF800000 }, .{ .qd = 0x00000000_7F800001_FFC00001_3F800000, .fpscr = 0x00040000 }),
    vec("vneg.f32 denormals and infinities, no flush", .{ .hw1 = 0xFFB9, .hw2 = 0x07C4, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0x3F800000_7F800000_807FFFFF_00000001 }, .{ .qd = 0xBF800000_FF800000_007FFFFF_80000001, .fpscr = 0x00040000 }),
    vec("vneg.f16 every lane kind", .{ .hw1 = 0xFFB5, .hw2 = 0x07C4, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0x3C007C00_83FF0001_8000FC01_7E01BC00 }, .{ .qd = 0xBC00FC00_03FF8001_00007C01_FE013C00, .fpscr = 0x00040000 }),
    vec("vneg.f32 qd = qm", .{ .hw1 = 0xFFB9, .hw2 = 0xA7CA, .qm = 0x80000000_FF800001_7FC00001_BF800000 }, .{ .qd = 0x00000000_7F800001_FFC00001_3F800000, .fpscr = 0x00040000 }),
    vec("vneg.f16 leaves fpscr flags and modes alone", .{ .hw1 = 0xFFB5, .hw2 = 0xE7C2, .qm = 0x3C007C00_83FF0001_8000FC01_7E01BC00, .fpscr = 0x0304009F }, .{ .qd = 0xBC00FC00_03FF8001_00007C01_FE013C00, .fpscr = 0x0304009F }),
};

const predicated = [_]V{
    vec("vpt p0 0x0f0e merges bytes, not lanes", .{ .hw1 = 0xFFB9, .hw2 = 0x07C4, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0x80000000_FF800001_7FC00001_BF800000, .vpr = 0x00880F0E }, .{ .qd = 0x11111111_7F800001_33333333_3F800044, .fpscr = 0x00040000, .vpr = 0x00000F0E }),
    vec("vpt f16 p0 0x3c03", .{ .hw1 = 0xFFB5, .hw2 = 0x0744, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0x3C007C00_83FF0001_8000FC01_7E01BC00, .vpr = 0x00883C03 }, .{ .qd = 0x11117C00_03FF2222_33333333_44443C00, .fpscr = 0x00040000, .vpr = 0x00003C03 }),
    vec("the loop tail keeps lanes 2 and 3", .{ .hw1 = 0xFFB9, .hw2 = 0x0744, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0x80000000_FF800001_7FC00001_BF800000, .lr = 2, .fpscr = 0x00020000 }, .{ .qd = 0x11111111_22222222_7FC00001_3F800000, .fpscr = 0x00020000 }),
    vec("the f16 loop tail at ltpsize 1", .{ .hw1 = 0xFFB5, .hw2 = 0x07C4, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0x3C007C00_83FF0001_8000FC01_7E01BC00, .lr = 5, .fpscr = 0x00010000 }, .{ .qd = 0x11111111_22228001_00007C01_FE013C00, .fpscr = 0x00010000 }),
    vec("eci a0 keeps beat 0", .{ .hw1 = 0xFFB9, .hw2 = 0x07C4, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0x80000000_FF800001_7FC00001_BF800000, .it = 0x10 }, .{ .qd = 0x00000000_7F800001_FFC00001_44444444, .fpscr = 0x00040000 }),
    vec("eci a0a1a2 keeps beats 0 to 2", .{ .hw1 = 0xFFB5, .hw2 = 0x0744, .qd = 0x11111111_22222222_33333333_44444444, .qm = 0x3C007C00_83FF0001_8000FC01_7E01BC00, .it = 0x40 }, .{ .qd = 0x3C007C00_22222222_33333333_44444444, .fpscr = 0x00040000 }),
};

const unclaimed = [_]V{
    vec("size 00 is unclaimed", .{ .hw1 = 0xFFB1, .hw2 = 0x0744 }, none),
    vec("size 11 is unclaimed", .{ .hw1 = 0xFFBD, .hw2 = 0x0744 }, none),
    vec("d set is unclaimed", .{ .hw1 = 0xFFF9, .hw2 = 0x0744 }, none),
    vec("m set is unclaimed", .{ .hw1 = 0xFFB9, .hw2 = 0x0764 }, none),
    vec("hw2[0] set is unclaimed", .{ .hw1 = 0xFFB9, .hw2 = 0x0745 }, none),
    vec("hw2[12] set is unclaimed", .{ .hw1 = 0xFFB9, .hw2 = 0x1744 }, none),
    vec("hw2[4] set is unclaimed", .{ .hw1 = 0xFFB9, .hw2 = 0x0754 }, none),
    vec("hw2[6] clear is unclaimed", .{ .hw1 = 0xFFB9, .hw2 = 0x0704 }, none),
    vec("hw1[1:0] other than 01 is unclaimed", .{ .hw1 = 0xFFBB, .hw2 = 0x0744 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xFFB9, .hw2 = 0x0744, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
