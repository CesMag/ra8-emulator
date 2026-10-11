//! Conformance vectors for the MVE VCVT forms between floating point and
//! integer or fixed point in float_int.zig, worked from the Arm ARM
//! (DDI0553) FPToFixed and FixedToFP pseudocode under StandardFPSCRValue.
const vector = @import("../../../conformance/vector.zig");
const flag = @import("../../../fpu/case.zig").flag;
const Rounding = @import("../../../fpu/rounding.zig").Rounding;
const float = @import("../float.zig");
const Out = @import("../vectors.zig").Out;

pub const Dir = enum { to_int, from_int };

pub const Operands = struct {
    d: u128 = 0,
    m: u128,
    size: float.Size,
    dir: Dir,
    unsigned: bool = false,
    rounding: Rounding = .zero,
    fbits: u6 = 0,
    mask: u16 = 0xFFFF,
};

const V = vector.Vector(Operands, Out);

// F32 lanes, low first: 2.5, -2.5, 0.5, -0.5.
const halves: u128 = 0xBF000000_3F000000_C0200000_40200000;

pub const vectors = [_]V{
    .{ .encoding = "VCVT.S32.F32 (MVE) T1", .name = "toward zero, saturation, NaN", .input = .{ .m = 0x7FC00000_4F32D05E_C0200000_3FC00000, .size = .word, .dir = .to_int }, .expect = .{ .q = 0x00000000_7FFFFFFF_FFFFFFFE_00000001, .flags = flag.ioc | flag.ixc } },
    .{ .encoding = "VCVT.U32.F32 (MVE) T1", .name = "negative, 3e9, 0.5, FZ flushes", .input = .{ .m = 0x00000001_3F000000_4F32D05E_BF800000, .size = .word, .dir = .to_int, .unsigned = true }, .expect = .{ .q = 0x00000000_00000000_B2D05E00_00000000, .flags = flag.ioc | flag.ixc | flag.idc } },
    .{ .encoding = "VCVT.S16.F16 (MVE) T1", .name = "16-bit saturation has no IXC", .input = .{ .m = 0x8000_5640_0001_3400_FC00_7BFF_BE00_3C00, .size = .half, .dir = .to_int }, .expect = .{ .q = 0x0000_0064_0000_0000_8000_7FFF_FFFF_0001, .flags = flag.ioc | flag.ixc } },
    .{ .encoding = "VCVT.U16.F16 (MVE) T1", .name = "65504, -1, inactive lanes kept", .input = .{ .d = 0x7777_7777_7777_7777_7777_7777_7777_7777, .m = 0x3C00_4000_BC00_7BFF, .size = .half, .dir = .to_int, .unsigned = true, .mask = 0x00FF }, .expect = .{ .q = 0x7777_7777_7777_7777_0001_0002_0000_FFE0, .flags = flag.ioc } },
    .{ .encoding = "VCVTA.S32.F32 (MVE) T1", .name = "ties away", .input = .{ .m = halves, .size = .word, .dir = .to_int, .rounding = .ties_away }, .expect = .{ .q = 0xFFFFFFFF_00000001_FFFFFFFD_00000003, .flags = flag.ixc } },
    .{ .encoding = "VCVTN.S32.F32 (MVE) T1", .name = "ties to even", .input = .{ .m = halves, .size = .word, .dir = .to_int, .rounding = .nearest }, .expect = .{ .q = 0x00000000_00000000_FFFFFFFE_00000002, .flags = flag.ixc } },
    .{ .encoding = "VCVTP.S32.F32 (MVE) T1", .name = "toward plus infinity", .input = .{ .m = halves, .size = .word, .dir = .to_int, .rounding = .plus_inf }, .expect = .{ .q = 0x00000000_00000001_FFFFFFFE_00000003, .flags = flag.ixc } },
    .{ .encoding = "VCVTM.S32.F32 (MVE) T1", .name = "toward minus infinity", .input = .{ .m = halves, .size = .word, .dir = .to_int, .rounding = .minus_inf }, .expect = .{ .q = 0xFFFFFFFF_00000000_FFFFFFFD_00000002, .flags = flag.ixc } },
    .{ .encoding = "VCVTA.U16.F16 (MVE) T1", .name = "ties away, a negative saturates to 0", .input = .{ .m = 0x3C00_B800_7BFF_4100, .size = .half, .dir = .to_int, .unsigned = true, .rounding = .ties_away }, .expect = .{ .q = 0x0001_0000_FFE0_0003, .flags = flag.ioc | flag.ixc } },
    .{ .encoding = "VCVT.F32.S32 (MVE) T1", .name = "1, -1, INT_MAX and 2^24+1 round", .input = .{ .m = 0x01000001_7FFFFFFF_FFFFFFFF_00000001, .size = .word, .dir = .from_int }, .expect = .{ .q = 0x4B800000_4F000000_BF800000_3F800000, .flags = flag.ixc } },
    .{ .encoding = "VCVT.F32.U32 (MVE) T1", .name = "UINT_MAX, 0, 3, 2^31", .input = .{ .m = 0x80000000_00000003_00000000_FFFFFFFF, .size = .word, .dir = .from_int, .unsigned = true }, .expect = .{ .q = 0x4F000000_40400000_00000000_4F800000, .flags = flag.ixc } },
    .{ .encoding = "VCVT.F16.S16 (MVE) T1", .name = "INT16 extremes and a tie to even", .input = .{ .m = 0x0003_0064_8000_0000_0801_7FFF_FFFF_0001, .size = .half, .dir = .from_int }, .expect = .{ .q = 0x4200_5640_F800_0000_6800_7800_BC00_3C00, .flags = flag.ixc } },
    .{ .encoding = "VCVT.F16.U16 (MVE) T1", .name = "65535 overflows to infinity", .input = .{ .m = 0x0001_FFE0_FFFF, .size = .half, .dir = .from_int, .unsigned = true }, .expect = .{ .q = 0x3C00_7BFF_7C00, .flags = flag.ofc | flag.ixc } },
    .{ .encoding = "VCVT.S32.F32 (MVE, fixed-point) T1", .name = "16 fraction bits", .input = .{ .m = 0x37000000_3F800000_BE800000_3FC00000, .size = .word, .dir = .to_int, .fbits = 16 }, .expect = .{ .q = 0x00000000_00010000_FFFFC000_00018000, .flags = flag.ixc } },
    .{ .encoding = "VCVT.F32.U32 (MVE, fixed-point) T1", .name = "1 fraction bit", .input = .{ .m = 0xFFFFFFFF_00000000_00000001_00000003, .size = .word, .dir = .from_int, .unsigned = true, .fbits = 1 }, .expect = .{ .q = 0x4F000000_00000000_3F000000_3FC00000, .flags = flag.ixc } },
    .{ .encoding = "VCVT.S16.F16 (MVE, fixed-point) T1", .name = "8 fraction bits, 200 saturates", .input = .{ .m = 0x5A40_3E00, .size = .half, .dir = .to_int, .fbits = 8 }, .expect = .{ .q = 0x7FFF_0180, .flags = flag.ioc } },
    .{ .encoding = "VCVT.F16.S16 (MVE, fixed-point) T1", .name = "4 fraction bits", .input = .{ .m = 0xFFF0_0018, .size = .half, .dir = .from_int, .fbits = 4 }, .expect = .{ .q = 0xBC00_3E00 } },
};

pub const claimed = [_][]const u8{
    "VCVT.S32.F32 (MVE) T1",              "VCVT.U32.F32 (MVE) T1",              "VCVT.S16.F16 (MVE) T1",              "VCVT.U16.F16 (MVE) T1",
    "VCVTA.S32.F32 (MVE) T1",             "VCVTN.S32.F32 (MVE) T1",             "VCVTP.S32.F32 (MVE) T1",             "VCVTM.S32.F32 (MVE) T1",
    "VCVTA.U16.F16 (MVE) T1",             "VCVT.F32.S32 (MVE) T1",              "VCVT.F32.U32 (MVE) T1",              "VCVT.F16.S16 (MVE) T1",
    "VCVT.F16.U16 (MVE) T1",              "VCVT.S32.F32 (MVE, fixed-point) T1", "VCVT.F32.U32 (MVE, fixed-point) T1", "VCVT.S16.F16 (MVE, fixed-point) T1",
    "VCVT.F16.S16 (MVE, fixed-point) T1",
};

pub const covered = vector.encodingsOf(Operands, Out, &vectors);
