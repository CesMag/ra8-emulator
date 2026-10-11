//! Conformance vectors for VSQRT, worked from FPSqrt in the Arm ARM
//! (DDI0553). Finite results were checked against an exact integer-root
//! model rounded per mode. They cover exact and irrational roots under
//! several modes, signed zeros, both infinities, negative operands, NaN
//! propagation including a negative NaN, denormal inputs, and FZ turning a
//! negative denormal into -0.
const vector = @import("../../conformance/vector.zig");
const case = @import("../case.zig");
const f = case.flag;

pub const V32 = vector.Vector(case.Unary(u32), case.Result(u32));
pub const V64 = vector.Vector(case.Unary(u64), case.Result(u64));

pub const sqrt32 = [_]V32{
    .{ .encoding = "VSQRT", .name = "sqrt 4", .input = .{ .a = 0x4080_0000 }, .expect = .{ .bits = 0x4000_0000 } },
    .{ .encoding = "VSQRT", .name = "sqrt 2, RN", .input = .{ .a = 0x4000_0000 }, .expect = .{ .bits = 0x3FB5_04F3, .flags = f.ixc } },
    .{ .encoding = "VSQRT", .name = "sqrt 2, RZ", .input = .{ .a = 0x4000_0000, .mode = .zero }, .expect = .{ .bits = 0x3FB5_04F3, .flags = f.ixc } },
    .{ .encoding = "VSQRT", .name = "sqrt 2, RP", .input = .{ .a = 0x4000_0000, .mode = .plus_inf }, .expect = .{ .bits = 0x3FB5_04F4, .flags = f.ixc } },
    .{ .encoding = "VSQRT", .name = "sqrt +0", .input = .{ .a = 0x0000_0000 }, .expect = .{ .bits = 0x0000_0000 } },
    .{ .encoding = "VSQRT", .name = "sqrt -0", .input = .{ .a = 0x8000_0000 }, .expect = .{ .bits = 0x8000_0000 } },
    .{ .encoding = "VSQRT", .name = "sqrt +inf", .input = .{ .a = 0x7F80_0000 }, .expect = .{ .bits = 0x7F80_0000 } },
    .{ .encoding = "VSQRT", .name = "sqrt -inf", .input = .{ .a = 0xFF80_0000 }, .expect = .{ .bits = 0x7FC0_0000, .flags = f.ioc } },
    .{ .encoding = "VSQRT", .name = "sqrt -1", .input = .{ .a = 0xBF80_0000 }, .expect = .{ .bits = 0x7FC0_0000, .flags = f.ioc } },
    .{ .encoding = "VSQRT", .name = "a negative qNaN propagates", .input = .{ .a = 0xFFC0_0001 }, .expect = .{ .bits = 0xFFC0_0001 } },
    .{ .encoding = "VSQRT", .name = "sNaN is quietened", .input = .{ .a = 0x7F80_0001 }, .expect = .{ .bits = 0x7FC0_0001, .flags = f.ioc } },
    .{ .encoding = "VSQRT", .name = "DN gives the default NaN", .input = .{ .a = 0xFFC0_0001, .dn = 1 }, .expect = .{ .bits = 0x7FC0_0000 } },
    .{ .encoding = "VSQRT", .name = "smallest denormal", .input = .{ .a = 0x0000_0001 }, .expect = .{ .bits = 0x1A35_04F3, .flags = f.ixc } },
    .{ .encoding = "VSQRT", .name = "2^-148 is exact", .input = .{ .a = 0x0000_0002 }, .expect = .{ .bits = 0x1A80_0000 } },
    .{ .encoding = "VSQRT", .name = "a negative denormal is invalid", .input = .{ .a = 0x8000_0001 }, .expect = .{ .bits = 0x7FC0_0000, .flags = f.ioc } },
    .{ .encoding = "VSQRT", .name = "FZ: a negative denormal is -0", .input = .{ .a = 0x8000_0001, .fz = 1 }, .expect = .{ .bits = 0x8000_0000, .flags = f.idc } },
    .{ .encoding = "VSQRT", .name = "max, RN", .input = .{ .a = 0x7F7F_FFFF }, .expect = .{ .bits = 0x5F7F_FFFF, .flags = f.ixc } },
    .{ .encoding = "VSQRT", .name = "max, RP", .input = .{ .a = 0x7F7F_FFFF, .mode = .plus_inf }, .expect = .{ .bits = 0x5F80_0000, .flags = f.ixc } },
    .{ .encoding = "VSQRT", .name = "1+ulp, RN", .input = .{ .a = 0x3F80_0001 }, .expect = .{ .bits = 0x3F80_0000, .flags = f.ixc } },
    .{ .encoding = "VSQRT", .name = "1+ulp, RP", .input = .{ .a = 0x3F80_0001, .mode = .plus_inf }, .expect = .{ .bits = 0x3F80_0001, .flags = f.ixc } },
};

pub const sqrt64 = [_]V64{
    .{ .encoding = "VSQRT", .name = "sqrt 4", .input = .{ .a = 0x4010_0000_0000_0000 }, .expect = .{ .bits = 0x4000_0000_0000_0000 } },
    .{ .encoding = "VSQRT", .name = "sqrt 2, RN", .input = .{ .a = 0x4000_0000_0000_0000 }, .expect = .{ .bits = 0x3FF6_A09E_667F_3BCD, .flags = f.ixc } },
    .{ .encoding = "VSQRT", .name = "sqrt 2, RM", .input = .{ .a = 0x4000_0000_0000_0000, .mode = .minus_inf }, .expect = .{ .bits = 0x3FF6_A09E_667F_3BCC, .flags = f.ixc } },
    .{ .encoding = "VSQRT", .name = "smallest denormal is exact", .input = .{ .a = 1 }, .expect = .{ .bits = 0x1E60_0000_0000_0000 } },
    .{ .encoding = "VSQRT", .name = "sqrt -1", .input = .{ .a = 0xBFF0_0000_0000_0000 }, .expect = .{ .bits = 0x7FF8_0000_0000_0000, .flags = f.ioc } },
    .{ .encoding = "VSQRT", .name = "sqrt -0", .input = .{ .a = 0x8000_0000_0000_0000 }, .expect = .{ .bits = 0x8000_0000_0000_0000 } },
};

pub const claimed = [_][]const u8{
    "VSQRT",
};

pub const covered = vector.encodingsOf(case.Unary(u32), case.Result(u32), &sqrt32) ++
    vector.encodingsOf(case.Unary(u64), case.Result(u64), &sqrt64);
