//! Conformance vectors for the MVE floating-point VABD, VABS and VNEG in
//! float.zig, worked from the Arm ARM (DDI0553) pseudocode. VABD is
//! FPAbs(FPSub) under StandardFPSCRValue, so a NaN comes out as the default
//! NaN; VABS and VNEG are FPAbs and FPNeg, which raise no flags and keep a
//! NaN's payload.
const vector = @import("../../conformance/vector.zig");
const flag = @import("../../fpu/case.zig").flag;
const float = @import("float.zig");
const Out = @import("vectors.zig").Out;

pub const Kind = enum { abd, abs, neg };

pub const Operands = struct {
    d: u128 = 0,
    a: u128,
    b: u128 = 0,
    size: float.Size,
    kind: Kind,
    mask: u16 = 0xFFFF,
};

const V = vector.Vector(Operands, Out);

pub const vectors = [_]V{
    .{ .encoding = "VABD.F32 (MVE) T1", .name = "|1-3|, |3-1|, signed sNaN, inf-inf", .input = .{ .a = 0x7F800000_FF800001_40400000_3F800000, .b = 0x7F800000_3F800000_3F800000_40400000, .size = .word, .kind = .abd }, .expect = .{ .q = 0x7FC00000_7FC00000_40000000_40000000, .flags = flag.ioc } },
    .{ .encoding = "VABD.F16 (MVE) T1", .name = "|1-2| under a half mask", .input = .{ .d = 0x1111_1111_1111_1111_1111_1111_1111_1111, .a = 0x3C00_3C00_3C00_3C00_3C00_3C00_3C00_3C00, .b = 0x4000_4000_4000_4000_4000_4000_4000_4000, .size = .half, .kind = .abd, .mask = 0x0F0F }, .expect = .{ .q = 0x1111_1111_3C00_3C00_1111_1111_3C00_3C00 } },
    .{ .encoding = "VABS.F32 (MVE) T1", .name = "-inf, -denormal, qNaN payload, -1", .input = .{ .a = 0xFF800000_80000001_FFC00001_BF800000, .size = .word, .kind = .abs }, .expect = .{ .q = 0x7F800000_00000001_7FC00001_3F800000 } },
    .{ .encoding = "VABS.F16 (MVE) T1", .name = "-1 under a word mask", .input = .{ .d = 0x2222_2222_2222_2222_2222_2222_2222_2222, .a = 0xBC00_BC00_BC00_BC00_BC00_BC00_BC00_BC00, .size = .half, .kind = .abs, .mask = 0xF00F }, .expect = .{ .q = 0x3C00_3C00_2222_2222_2222_2222_3C00_3C00 } },
    .{ .encoding = "VNEG.F32 (MVE) T1", .name = "1, qNaN, +0, -denormal", .input = .{ .a = 0x3F800000_7FC00000_00000000_80000001, .size = .word, .kind = .neg }, .expect = .{ .q = 0xBF800000_FFC00000_80000000_00000001 } },
    .{ .encoding = "VNEG.F16 (MVE) T1", .name = "ones, zeros, infinities, NaN, denormal", .input = .{ .a = 0x3C00_BC00_0000_8000_7C00_FC00_7E01_0001, .size = .half, .kind = .neg }, .expect = .{ .q = 0xBC00_3C00_8000_0000_FC00_7C00_FE01_8001 } },
};

pub const claimed = [_][]const u8{ "VABD.F16 (MVE) T1", "VABD.F32 (MVE) T1", "VABS.F16 (MVE) T1", "VABS.F32 (MVE) T1", "VNEG.F16 (MVE) T1", "VNEG.F32 (MVE) T1" };

pub const covered = vector.encodingsOf(Operands, Out, &vectors);
