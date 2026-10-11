//! Conformance vectors for the decode group `mve_float_maxnmv` (RA8EMU-278):
//! VMAXNMV, VMINNMV, VMAXNMAV and VMINNMAV on F32 and F16 lanes, folding
//! the predicated lanes of Qm into Rda. Expected values are worked from the
//! Arm ARM (DDI0553) pseudocode: lane by lane, a signalling NaN in the
//! running value or the lane is quietened with IOC, the AV forms take the
//! lane's absolute value (never Rda's), and FPMaxNum or FPMinNum runs under
//! StandardFPSCRValue (an F32 denormal reads as zero with IDC; FZ16 is
//! clear here, so F16 denormals stay). Only lanes whose first byte is in
//! the mask (VPT, loop tail) fold. The F16 forms read Rda's low half and
//! zero-extend the result. Rda of SP or PC, M set, the integer VMAXV space,
//! flipped fixed bits and the 16-bit space are left unclaimed.
const vector = @import("../../../vector.zig");

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    qm: u128 = 0,
    rda: u32 = 0,
    vpr: u32 = 0,
    lr: u32 = 0,
    fpscr: u32 = 0x0004_0000,
};

pub const Out = struct {
    claimed: bool = true,
    rda: u32,
    fpscr: u32,
    vpr: u32 = 0,
};

const V = vector.Vector(In, Out);
const group = "mve_float_maxnmv";
pub const none: Out = .{ .claimed = false, .rda = 0, .fpscr = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = forms ++ predicated ++ unclaimed;

const forms = [_]V{
    vec("vmaxnmv.f32 mixed signs from a zero start", .{ .hw1 = 0xEEEE, .hw2 = 0x2F02, .qm = 0xBF000000_40200000_C0400000_3F800000, .rda = 0x0 }, .{ .rda = 0x40200000, .fpscr = 0x00040000 }),
    vec("vmaxnmv.f32 quiet nan, infinity, flushed denormal", .{ .hw1 = 0xEEEE, .hw2 = 0x2F02, .qm = 0x80000000_00000001_FF800000_7FC00001, .rda = 0x3F000000 }, .{ .rda = 0x3F000000, .fpscr = 0x00040080 }),
    vec("vmaxnmv.f32 snan lane is quietened with ioc then loses", .{ .hw1 = 0xEEEE, .hw2 = 0x2F02, .qm = 0x7FC00001_7F800000_3F800000_7F800001, .rda = 0xC0000000 }, .{ .rda = 0x7F800000, .fpscr = 0x00040001 }),
    vec("vmaxnmv.f16 mixed with extremes", .{ .hw1 = 0xFEEE, .hw2 = 0x2F02, .qm = 0x80000001_FBFF7BFF_B8004100_C2003C00, .rda = 0xFFFF3800 }, .{ .rda = 0x7BFF, .fpscr = 0x00040000 }),
    vec("vmaxnmv.f16 nans and kept denormals", .{ .hw1 = 0xFEEE, .hw2 = 0x2F02, .qm = 0xC0007E00_00008001_FC003C00_7C017E01, .rda = 0x8000 }, .{ .rda = 0x3C00, .fpscr = 0x00040001 }),
    vec("vminnmv.f32 mixed signs from a zero start", .{ .hw1 = 0xEEEE, .hw2 = 0x2F82, .qm = 0xBF000000_40200000_C0400000_3F800000, .rda = 0x0 }, .{ .rda = 0xC0400000, .fpscr = 0x00040000 }),
    vec("vminnmv.f32 quiet nan, infinity, flushed denormal", .{ .hw1 = 0xEEEE, .hw2 = 0x2F82, .qm = 0x80000000_00000001_FF800000_7FC00001, .rda = 0x3F000000 }, .{ .rda = 0xFF800000, .fpscr = 0x00040080 }),
    vec("vminnmv.f32 snan lane is quietened with ioc then loses", .{ .hw1 = 0xEEEE, .hw2 = 0x2F82, .qm = 0x7FC00001_7F800000_3F800000_7F800001, .rda = 0xC0000000 }, .{ .rda = 0xC0000000, .fpscr = 0x00040001 }),
    vec("vminnmv.f16 mixed with extremes", .{ .hw1 = 0xFEEE, .hw2 = 0x2F82, .qm = 0x80000001_FBFF7BFF_B8004100_C2003C00, .rda = 0xFFFF3800 }, .{ .rda = 0xFBFF, .fpscr = 0x00040000 }),
    vec("vminnmv.f16 nans and kept denormals", .{ .hw1 = 0xFEEE, .hw2 = 0x2F82, .qm = 0xC0007E00_00008001_FC003C00_7C017E01, .rda = 0x8000 }, .{ .rda = 0xFC00, .fpscr = 0x00040001 }),
    vec("vmaxnmav.f32 mixed signs from a zero start", .{ .hw1 = 0xEEEC, .hw2 = 0x2F02, .qm = 0xBF000000_40200000_C0400000_3F800000, .rda = 0x0 }, .{ .rda = 0x40400000, .fpscr = 0x00040000 }),
    vec("vmaxnmav.f32 quiet nan, infinity, flushed denormal", .{ .hw1 = 0xEEEC, .hw2 = 0x2F02, .qm = 0x80000000_00000001_FF800000_7FC00001, .rda = 0x3F000000 }, .{ .rda = 0x7F800000, .fpscr = 0x00040080 }),
    vec("vmaxnmav.f32 snan lane is quietened with ioc then loses", .{ .hw1 = 0xEEEC, .hw2 = 0x2F02, .qm = 0x7FC00001_7F800000_3F800000_7F800001, .rda = 0xC0000000 }, .{ .rda = 0x7F800000, .fpscr = 0x00040001 }),
    vec("vmaxnmav.f16 mixed with extremes", .{ .hw1 = 0xFEEC, .hw2 = 0x2F02, .qm = 0x80000001_FBFF7BFF_B8004100_C2003C00, .rda = 0xFFFF3800 }, .{ .rda = 0x7BFF, .fpscr = 0x00040000 }),
    vec("vmaxnmav.f16 nans and kept denormals", .{ .hw1 = 0xFEEC, .hw2 = 0x2F02, .qm = 0xC0007E00_00008001_FC003C00_7C017E01, .rda = 0x8000 }, .{ .rda = 0x7C00, .fpscr = 0x00040001 }),
    vec("vminnmav.f32 mixed signs from a zero start", .{ .hw1 = 0xEEEC, .hw2 = 0x2F82, .qm = 0xBF000000_40200000_C0400000_3F800000, .rda = 0x0 }, .{ .rda = 0x0, .fpscr = 0x00040000 }),
    vec("vminnmav.f32 quiet nan, infinity, flushed denormal", .{ .hw1 = 0xEEEC, .hw2 = 0x2F82, .qm = 0x80000000_00000001_FF800000_7FC00001, .rda = 0x3F000000 }, .{ .rda = 0x0, .fpscr = 0x00040080 }),
    vec("vminnmav.f32 snan lane is quietened with ioc then loses", .{ .hw1 = 0xEEEC, .hw2 = 0x2F82, .qm = 0x7FC00001_7F800000_3F800000_7F800001, .rda = 0xC0000000 }, .{ .rda = 0xC0000000, .fpscr = 0x00040001 }),
    vec("vminnmav.f16 mixed with extremes", .{ .hw1 = 0xFEEC, .hw2 = 0x2F82, .qm = 0x80000001_FBFF7BFF_B8004100_C2003C00, .rda = 0xFFFF3800 }, .{ .rda = 0x0, .fpscr = 0x00040000 }),
    vec("vminnmav.f16 nans and kept denormals", .{ .hw1 = 0xFEEC, .hw2 = 0x2F82, .qm = 0xC0007E00_00008001_FC003C00_7C017E01, .rda = 0x8000 }, .{ .rda = 0x8000, .fpscr = 0x00040001 }),
    vec("vmaxnmv.f32 a quiet nan in rda loses to the lanes", .{ .hw1 = 0xEEEE, .hw2 = 0x2F02, .qm = 0xBF000000_40200000_C0400000_3F800000, .rda = 0x7FC00001 }, .{ .rda = 0x40200000, .fpscr = 0x00040000 }),
    vec("vminnmv.f32 an snan in rda is quietened with ioc", .{ .hw1 = 0xEEEE, .hw2 = 0x2F82, .qm = 0xBF000000_40200000_C0400000_3F800000, .rda = 0x7F800001 }, .{ .rda = 0xC0400000, .fpscr = 0x00040001 }),
    vec("vmaxnmav.f32 takes the lane magnitude but keeps a negative rda", .{ .hw1 = 0xEEEC, .hw2 = 0x2F02, .qm = 0x80000000_80000000_80000000_80000000, .rda = 0xBF800000 }, .{ .rda = 0x0, .fpscr = 0x00040000 }),
    vec("vminnmv.f16 ignores the top half of rda and zero-extends", .{ .hw1 = 0xFEEE, .hw2 = 0x2F82, .qm = 0x80000001_FBFF7BFF_B8004100_C2003C00, .rda = 0xABCD7C00 }, .{ .rda = 0xFBFF, .fpscr = 0x00040000 }),
    vec("vmaxnmv.f32 into r12 from q7", .{ .hw1 = 0xEEEE, .hw2 = 0xCF0E, .qm = 0xBF000000_40200000_C0400000_3F800000, .rda = 0xFF800000 }, .{ .rda = 0x40200000, .fpscr = 0x00040000 }),
    vec("vmaxnmv.f32 into lr", .{ .hw1 = 0xEEEE, .hw2 = 0xEF02, .qm = 0xBF000000_40200000_C0400000_3F800000, .rda = 0x0 }, .{ .rda = 0x40200000, .fpscr = 0x00040000 }),
    vec("flags add to the cumulative bits already set", .{ .hw1 = 0xEEEE, .hw2 = 0x2F02, .qm = 0x7FC00001_7F800000_3F800000_7F800001, .rda = 0x0, .fpscr = 0x00040010 }, .{ .rda = 0x7F800000, .fpscr = 0x00040011 }),
};

const predicated = [_]V{
    vec("vpt p0 0x0f0f folds lanes 0 and 1", .{ .hw1 = 0xEEEE, .hw2 = 0x2F02, .qm = 0x7FC00001_7F800000_3F800000_7F800001, .rda = 0x0, .vpr = 0x008800FF }, .{ .rda = 0x3F800000, .fpscr = 0x00040001, .vpr = 0x000000FF }),
    vec("vpt p0 0xfff0 skips lane 0 and its snan", .{ .hw1 = 0xEEEE, .hw2 = 0x2F82, .qm = 0x7FC00001_7F800000_3F800000_7F800001, .rda = 0x0, .vpr = 0x0088FFF0 }, .{ .rda = 0x0, .fpscr = 0x00040000, .vpr = 0x0000FFF0 }),
    vec("a lane folds only when its first byte is predicated", .{ .hw1 = 0xEEEE, .hw2 = 0x2F02, .qm = 0x7FC00001_7F800000_3F800000_7F800001, .rda = 0x0, .vpr = 0x0088FFFE }, .{ .rda = 0x7F800000, .fpscr = 0x00040000, .vpr = 0x0000FFFE }),
    vec("the loop tail stops at lane 2", .{ .hw1 = 0xEEEE, .hw2 = 0x2F02, .qm = 0xBF000000_40200000_C0400000_3F800000, .rda = 0x0, .lr = 2, .fpscr = 0x00020000 }, .{ .rda = 0x3F800000, .fpscr = 0x00020000 }),
    vec("the f16 loop tail at ltpsize 1", .{ .hw1 = 0xFEEE, .hw2 = 0x2F82, .qm = 0xC0007E00_00008001_FC003C00_7C017E01, .rda = 0x0, .lr = 3, .fpscr = 0x00010000 }, .{ .rda = 0x0, .fpscr = 0x00010001 }),
    vec("no predicated lanes leave rda as is", .{ .hw1 = 0xEEEE, .hw2 = 0x2F02, .qm = 0x7FC00001_7F800000_3F800000_7F800001, .rda = 0x12345678, .vpr = 0x00880000 }, .{ .rda = 0x12345678, .fpscr = 0x00040000 }),
};

const unclaimed = [_]V{
    vec("rda = sp is unclaimed", .{ .hw1 = 0xEEEE, .hw2 = 0xDF02 }, none),
    vec("rda = pc is unclaimed", .{ .hw1 = 0xEEEE, .hw2 = 0xFF02 }, none),
    vec("m set is unclaimed", .{ .hw1 = 0xEEEE, .hw2 = 0x2F22 }, none),
    vec("hw2[0] set is unclaimed", .{ .hw1 = 0xEEEE, .hw2 = 0x2F03 }, none),
    vec("hw2[6] set is unclaimed", .{ .hw1 = 0xEEEE, .hw2 = 0x2F42 }, none),
    vec("hw2[11:8] other than 1111 is unclaimed", .{ .hw1 = 0xEEEE, .hw2 = 0x2E02 }, none),
    vec("hw1[0] set is unclaimed", .{ .hw1 = 0xEEEF, .hw2 = 0x2F02 }, none),
    vec("integer vmaxv size 10 is not this group", .{ .hw1 = 0xEEE2, .hw2 = 0x2F02 }, none),
    vec("hw1[15:13] other than 111 is unclaimed", .{ .hw1 = 0xCEEE, .hw2 = 0x2F02 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEEEE, .hw2 = 0x2F02, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
