//! Conformance vectors for the decode group `mve_vcmp_fp` (RA8EMU-278): the
//! F32 and F16 VCMP and VPT forms, vector by vector and vector by scalar,
//! for EQ, NE, GE, LT, GT and LE. Expected values are worked from the Arm
//! ARM (DDI0553) pseudocode: FPCompareEQ, FPCompareGE or FPCompareGT under
//! StandardFPSCRValue, NE, LT and LE being their negations, so an
//! unordered lane is true for exactly those three. EQ and NE raise IOC
//! only for a signalling NaN, the ordered conditions for any NaN; an F32
//! denormal reads as zero with IDC (FZ16 is clear here), and -0 equals +0.
//! A lane is compared when any of its bytes is in the mask (VPT, loop
//! tail, EPSR.ECI), its flags count only when its first byte is, and its
//! P0 bits are masked; P0 bytes of done beats keep their value. A VCMP in a
//! block advances it; a VPT opens its mask in each pair whose odd beat is
//! still pending. Qn and Qm are written in that order. fc2=0 with fc0=1,
//! Rm of SP or PC, flipped fixed bits and the 16-bit space are unclaimed.
const vector = @import("../../../vector.zig");

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    qn: u128 = 0,
    qm: u128 = 0,
    rm: u32 = 0,
    vpr: u32 = 0,
    it: u8 = 0,
    lr: u32 = 0,
    fpscr: u32 = 0x0004_0000,
};

pub const Out = struct {
    claimed: bool = true,
    vpr: u32,
    fpscr: u32,
    it: u8 = 0,
};

const V = vector.Vector(In, Out);
const group = "mve_vcmp_fp";
pub const none: Out = .{ .claimed = false, .vpr = 0, .fpscr = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = by_vector ++ by_scalar ++ blocks ++ unclaimed;

const by_vector = [_]V{
    vec("vcmp.f32 eq ordered and signed zeros", .{ .hw1 = 0xEE33, .hw2 = 0x0F04, .qn = 0x80000000_00000000_C0000000_3F800000, .qm = 0xBF800000_80000000_40400000_3F800000 }, .{ .vpr = 0x00000F0F, .fpscr = 0x00040000 }),
    vec("vcmp.f32 eq nans, a flushed denormal, infinities", .{ .hw1 = 0xEE33, .hw2 = 0x0F04, .qn = 0x7F800000_00000001_40000000_7FC00001, .qm = 0x7F800000_00000000_7F800001_3F800000 }, .{ .vpr = 0x0000FF00, .fpscr = 0x00040081 }),
    vec("vcmp.f16 eq mixed lanes with a quiet nan", .{ .hw1 = 0xFE33, .hw2 = 0x0F04, .qn = 0x7BFF7C00_00017E01_80000000_C0003C00, .qm = 0xFBFFFC00_00003C00_BC008000_42003C00 }, .{ .vpr = 0x00000033, .fpscr = 0x00040000 }),
    vec("vcmp.f32 ne ordered and signed zeros", .{ .hw1 = 0xEE33, .hw2 = 0x0F84, .qn = 0x80000000_00000000_C0000000_3F800000, .qm = 0xBF800000_80000000_40400000_3F800000 }, .{ .vpr = 0x0000F0F0, .fpscr = 0x00040000 }),
    vec("vcmp.f32 ne nans, a flushed denormal, infinities", .{ .hw1 = 0xEE33, .hw2 = 0x0F84, .qn = 0x7F800000_00000001_40000000_7FC00001, .qm = 0x7F800000_00000000_7F800001_3F800000 }, .{ .vpr = 0x000000FF, .fpscr = 0x00040081 }),
    vec("vcmp.f16 ne mixed lanes with a quiet nan", .{ .hw1 = 0xFE33, .hw2 = 0x0F84, .qn = 0x7BFF7C00_00017E01_80000000_C0003C00, .qm = 0xFBFFFC00_00003C00_BC008000_42003C00 }, .{ .vpr = 0x0000FFCC, .fpscr = 0x00040000 }),
    vec("vcmp.f32 ge ordered and signed zeros", .{ .hw1 = 0xEE33, .hw2 = 0x1F04, .qn = 0x80000000_00000000_C0000000_3F800000, .qm = 0xBF800000_80000000_40400000_3F800000 }, .{ .vpr = 0x0000FF0F, .fpscr = 0x00040000 }),
    vec("vcmp.f32 ge nans, a flushed denormal, infinities", .{ .hw1 = 0xEE33, .hw2 = 0x1F04, .qn = 0x7F800000_00000001_40000000_7FC00001, .qm = 0x7F800000_00000000_7F800001_3F800000 }, .{ .vpr = 0x0000FF00, .fpscr = 0x00040081 }),
    vec("vcmp.f16 ge mixed lanes with a quiet nan", .{ .hw1 = 0xFE33, .hw2 = 0x1F04, .qn = 0x7BFF7C00_00017E01_80000000_C0003C00, .qm = 0xFBFFFC00_00003C00_BC008000_42003C00 }, .{ .vpr = 0x0000FCF3, .fpscr = 0x00040001 }),
    vec("vcmp.f32 lt ordered and signed zeros", .{ .hw1 = 0xEE33, .hw2 = 0x1F84, .qn = 0x80000000_00000000_C0000000_3F800000, .qm = 0xBF800000_80000000_40400000_3F800000 }, .{ .vpr = 0x000000F0, .fpscr = 0x00040000 }),
    vec("vcmp.f32 lt nans, a flushed denormal, infinities", .{ .hw1 = 0xEE33, .hw2 = 0x1F84, .qn = 0x7F800000_00000001_40000000_7FC00001, .qm = 0x7F800000_00000000_7F800001_3F800000 }, .{ .vpr = 0x000000FF, .fpscr = 0x00040081 }),
    vec("vcmp.f16 lt mixed lanes with a quiet nan", .{ .hw1 = 0xFE33, .hw2 = 0x1F84, .qn = 0x7BFF7C00_00017E01_80000000_C0003C00, .qm = 0xFBFFFC00_00003C00_BC008000_42003C00 }, .{ .vpr = 0x0000030C, .fpscr = 0x00040001 }),
    vec("vcmp.f32 gt ordered and signed zeros", .{ .hw1 = 0xEE33, .hw2 = 0x1F05, .qn = 0x80000000_00000000_C0000000_3F800000, .qm = 0xBF800000_80000000_40400000_3F800000 }, .{ .vpr = 0x0000F000, .fpscr = 0x00040000 }),
    vec("vcmp.f32 gt nans, a flushed denormal, infinities", .{ .hw1 = 0xEE33, .hw2 = 0x1F05, .qn = 0x7F800000_00000001_40000000_7FC00001, .qm = 0x7F800000_00000000_7F800001_3F800000 }, .{ .vpr = 0x00000000, .fpscr = 0x00040081 }),
    vec("vcmp.f16 gt mixed lanes with a quiet nan", .{ .hw1 = 0xFE33, .hw2 = 0x1F05, .qn = 0x7BFF7C00_00017E01_80000000_C0003C00, .qm = 0xFBFFFC00_00003C00_BC008000_42003C00 }, .{ .vpr = 0x0000FCC0, .fpscr = 0x00040001 }),
    vec("vcmp.f32 le ordered and signed zeros", .{ .hw1 = 0xEE33, .hw2 = 0x1F85, .qn = 0x80000000_00000000_C0000000_3F800000, .qm = 0xBF800000_80000000_40400000_3F800000 }, .{ .vpr = 0x00000FFF, .fpscr = 0x00040000 }),
    vec("vcmp.f32 le nans, a flushed denormal, infinities", .{ .hw1 = 0xEE33, .hw2 = 0x1F85, .qn = 0x7F800000_00000001_40000000_7FC00001, .qm = 0x7F800000_00000000_7F800001_3F800000 }, .{ .vpr = 0x0000FFFF, .fpscr = 0x00040081 }),
    vec("vcmp.f16 le mixed lanes with a quiet nan", .{ .hw1 = 0xFE33, .hw2 = 0x1F85, .qn = 0x7BFF7C00_00017E01_80000000_C0003C00, .qm = 0xFBFFFC00_00003C00_BC008000_42003C00 }, .{ .vpr = 0x0000033F, .fpscr = 0x00040001 }),
    vec("vcmp.f32 ge q7 with itself", .{ .hw1 = 0xEE3F, .hw2 = 0x1F0E, .qn = 0x7F800000_00000001_40000000_7FC00001 }, .{ .vpr = 0x0000FFFF, .fpscr = 0x00040000 }),
    vec("flags add to bits already set and fz clear still flushes", .{ .hw1 = 0xEE33, .hw2 = 0x1F84, .qn = 0x7F800000_00000001_40000000_7FC00001, .qm = 0x7F800000_00000000_7F800001_3F800000, .fpscr = 0x00040010 }, .{ .vpr = 0x000000FF, .fpscr = 0x00040091 }),
};

const by_scalar = [_]V{
    vec("vcmp.f32 eq against r2 = 1.0", .{ .hw1 = 0xEE33, .hw2 = 0x0F42, .qn = 0x7FC00001_40000000_3F800000_3F000000, .rm = 0x3F800000 }, .{ .vpr = 0x000000F0, .fpscr = 0x00040000 }),
    vec("vcmp.f16 eq against the low half of r2, with an snan lane", .{ .hw1 = 0xFE33, .hw2 = 0x0F42, .qn = 0x80010001_7E00B800_38004000_3C007C01, .rm = 0xBC003C00 }, .{ .vpr = 0x0000000C, .fpscr = 0x00040001 }),
    vec("vcmp.f32 ne against r2 = 1.0", .{ .hw1 = 0xEE33, .hw2 = 0x0FC2, .qn = 0x7FC00001_40000000_3F800000_3F000000, .rm = 0x3F800000 }, .{ .vpr = 0x0000FF0F, .fpscr = 0x00040000 }),
    vec("vcmp.f16 ne against the low half of r2, with an snan lane", .{ .hw1 = 0xFE33, .hw2 = 0x0FC2, .qn = 0x80010001_7E00B800_38004000_3C007C01, .rm = 0xBC003C00 }, .{ .vpr = 0x0000FFF3, .fpscr = 0x00040001 }),
    vec("vcmp.f32 ge against r2 = 1.0", .{ .hw1 = 0xEE33, .hw2 = 0x1F42, .qn = 0x7FC00001_40000000_3F800000_3F000000, .rm = 0x3F800000 }, .{ .vpr = 0x00000FF0, .fpscr = 0x00040001 }),
    vec("vcmp.f16 ge against the low half of r2, with an snan lane", .{ .hw1 = 0xFE33, .hw2 = 0x1F42, .qn = 0x80010001_7E00B800_38004000_3C007C01, .rm = 0xBC003C00 }, .{ .vpr = 0x0000003C, .fpscr = 0x00040001 }),
    vec("vcmp.f32 lt against r2 = 1.0", .{ .hw1 = 0xEE33, .hw2 = 0x1FC2, .qn = 0x7FC00001_40000000_3F800000_3F000000, .rm = 0x3F800000 }, .{ .vpr = 0x0000F00F, .fpscr = 0x00040001 }),
    vec("vcmp.f16 lt against the low half of r2, with an snan lane", .{ .hw1 = 0xFE33, .hw2 = 0x1FC2, .qn = 0x80010001_7E00B800_38004000_3C007C01, .rm = 0xBC003C00 }, .{ .vpr = 0x0000FFC3, .fpscr = 0x00040001 }),
    vec("vcmp.f32 gt against r2 = 1.0", .{ .hw1 = 0xEE33, .hw2 = 0x1F62, .qn = 0x7FC00001_40000000_3F800000_3F000000, .rm = 0x3F800000 }, .{ .vpr = 0x00000F00, .fpscr = 0x00040001 }),
    vec("vcmp.f16 gt against the low half of r2, with an snan lane", .{ .hw1 = 0xFE33, .hw2 = 0x1F62, .qn = 0x80010001_7E00B800_38004000_3C007C01, .rm = 0xBC003C00 }, .{ .vpr = 0x00000030, .fpscr = 0x00040001 }),
    vec("vcmp.f32 le against r2 = 1.0", .{ .hw1 = 0xEE33, .hw2 = 0x1FE2, .qn = 0x7FC00001_40000000_3F800000_3F000000, .rm = 0x3F800000 }, .{ .vpr = 0x0000F0FF, .fpscr = 0x00040001 }),
    vec("vcmp.f16 le against the low half of r2, with an snan lane", .{ .hw1 = 0xFE33, .hw2 = 0x1FE2, .qn = 0x80010001_7E00B800_38004000_3C007C01, .rm = 0xBC003C00 }, .{ .vpr = 0x0000FFCF, .fpscr = 0x00040001 }),
    vec("vcmp.f32 eq against a signalling nan in r12 raises ioc", .{ .hw1 = 0xEE33, .hw2 = 0x0F4C, .qn = 0x80000000_00000000_C0000000_3F800000, .rm = 0x7F800001 }, .{ .vpr = 0x00000000, .fpscr = 0x00040001 }),
    vec("vcmp.f32 gt against a quiet nan in lr raises ioc", .{ .hw1 = 0xEE33, .hw2 = 0x1F6E, .qn = 0x80000000_00000000_C0000000_3F800000, .rm = 0x7FC00001 }, .{ .vpr = 0x00000000, .fpscr = 0x00040001 }),
};

const blocks = [_]V{
    vec("vpt.f32 ge opens a one-instruction block", .{ .hw1 = 0xEE73, .hw2 = 0x1F04, .qn = 0x80000000_00000000_C0000000_3F800000, .qm = 0xBF800000_80000000_40400000_3F800000 }, .{ .vpr = 0x0088FF0F, .fpscr = 0x00040000 }),
    vec("vptt.f16 ne opens a two-instruction block", .{ .hw1 = 0xFE33, .hw2 = 0x8F84, .qn = 0x7BFF7C00_00017E01_80000000_C0003C00, .qm = 0xFBFFFC00_00003C00_BC008000_42003C00 }, .{ .vpr = 0x0044FFCC, .fpscr = 0x00040000 }),
    vec("vpteee.f32 lt against r2", .{ .hw1 = 0xEE73, .hw2 = 0xDFC2, .qn = 0x80000000_00000000_C0000000_3F800000, .rm = 0x0 }, .{ .vpr = 0x00EE00F0, .fpscr = 0x00040000 }),
    vec("vcmp in a vpt block ands with p0 and drops lane 0 flags", .{ .hw1 = 0xEE33, .hw2 = 0x1F05, .qn = 0x7F800000_00000001_40000000_7FC00001, .qm = 0x7F800000_00000000_7F800001_3F800000, .vpr = 0x0088FFF0 }, .{ .vpr = 0x00000000, .fpscr = 0x00040081 }),
    vec("the loop tail clears p0 past lane 1", .{ .hw1 = 0xEE33, .hw2 = 0x0F84, .qn = 0x7F800000_00000001_40000000_7FC00001, .qm = 0x7F800000_00000000_7F800001_3F800000, .vpr = 0x0000FFFF, .lr = 2, .fpscr = 0x00020000 }, .{ .vpr = 0x000000FF, .fpscr = 0x00020001 }),
    vec("eci a0a1 keeps the done beats of p0", .{ .hw1 = 0xEE33, .hw2 = 0x1F85, .qn = 0x7F800000_00000001_40000000_7FC00001, .qm = 0x7F800000_00000000_7F800001_3F800000, .vpr = 0x0000A5A5, .it = 0x20 }, .{ .vpr = 0x0000FFA5, .fpscr = 0x00040080 }),
    vec("vpt with eci a0a1a2 opens only mask23", .{ .hw1 = 0xFE73, .hw2 = 0x0F04, .qn = 0x7BFF7C00_00017E01_80000000_C0003C00, .qm = 0xFBFFFC00_00003C00_BC008000_42003C00, .vpr = 0x00001234, .it = 0x40 }, .{ .vpr = 0x00800234, .fpscr = 0x00040000 }),
};

const unclaimed = [_]V{
    vec("fc2=0 with fc0=1 is unclaimed", .{ .hw1 = 0xEE33, .hw2 = 0x0F05 }, none),
    vec("the scalar form with fc2=0, fc0=1 is unclaimed", .{ .hw1 = 0xEE33, .hw2 = 0x0F62 }, none),
    vec("rm = sp is unclaimed", .{ .hw1 = 0xEE33, .hw2 = 0x0F4D }, none),
    vec("rm = pc is unclaimed", .{ .hw1 = 0xEE33, .hw2 = 0x0F4F }, none),
    vec("the vector form with hw2[5] set is unclaimed", .{ .hw1 = 0xEE33, .hw2 = 0x0F24 }, none),
    vec("hw2[4] set is unclaimed", .{ .hw1 = 0xEE33, .hw2 = 0x0F14 }, none),
    vec("hw2[11:8] other than 1111 is unclaimed", .{ .hw1 = 0xEE33, .hw2 = 0x0E04 }, none),
    vec("hw1[0] clear is unclaimed", .{ .hw1 = 0xEE32, .hw2 = 0x0F04 }, none),
    vec("integer size 10 is not this group", .{ .hw1 = 0xFE23, .hw2 = 0x0F04 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEE33, .hw2 = 0x0F04, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
