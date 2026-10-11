//! Conformance vectors for VRINTA, VRINTN, VRINTP, VRINTM, VRINTZ, VRINTR
//! and VRINTX, worked from FPRoundInt in the Arm ARM (DDI0553). They cover
//! each rounding and its ties, zero results keeping the operand's sign,
//! values that are already integral, denormals with and without FZ, NaN
//! handling, and IXC raised only by VRINTX.
const vector = @import("../../conformance/vector.zig");
const case = @import("../case.zig");
const f = case.flag;

pub const V32 = vector.Vector(case.Integral(u32), case.Result(u32));
pub const V64 = vector.Vector(case.Integral(u64), case.Result(u64));

pub const rint32 = [_]V32{
    .{ .encoding = "VRINTA", .name = "2.5 ties away", .input = .{ .a = 0x4020_0000, .rounding = .ties_away }, .expect = .{ .bits = 0x4040_0000 } },
    .{ .encoding = "VRINTA", .name = "-2.5 ties away", .input = .{ .a = 0xC020_0000, .rounding = .ties_away }, .expect = .{ .bits = 0xC040_0000 } },
    .{ .encoding = "VRINTA", .name = "0.5 ties away to 1", .input = .{ .a = 0x3F00_0000, .rounding = .ties_away }, .expect = .{ .bits = 0x3F80_0000 } },
    .{ .encoding = "VRINTA", .name = "-0.4 keeps its sign as -0", .input = .{ .a = 0xBECC_CCCD, .rounding = .ties_away }, .expect = .{ .bits = 0x8000_0000 } },
    .{ .encoding = "VRINTA", .name = "qNaN propagates", .input = .{ .a = 0xFFC0_0001, .rounding = .ties_away }, .expect = .{ .bits = 0xFFC0_0001 } },
    .{ .encoding = "VRINTA", .name = "sNaN is quietened", .input = .{ .a = 0x7F80_0001, .rounding = .ties_away }, .expect = .{ .bits = 0x7FC0_0001, .flags = f.ioc } },
    .{ .encoding = "VRINTA", .name = "DN gives the default NaN", .input = .{ .a = 0xFFC0_0001, .rounding = .ties_away, .dn = 1 }, .expect = .{ .bits = 0x7FC0_0000 } },
    .{ .encoding = "VRINTA", .name = "-inf", .input = .{ .a = 0xFF80_0000, .rounding = .ties_away }, .expect = .{ .bits = 0xFF80_0000 } },
    .{ .encoding = "VRINTN", .name = "2.5 ties to even", .input = .{ .a = 0x4020_0000, .rounding = .nearest }, .expect = .{ .bits = 0x4000_0000 } },
    .{ .encoding = "VRINTN", .name = "3.5 ties to even", .input = .{ .a = 0x4060_0000, .rounding = .nearest }, .expect = .{ .bits = 0x4080_0000 } },
    .{ .encoding = "VRINTN", .name = "-0.5 ties to -0", .input = .{ .a = 0xBF00_0000, .rounding = .nearest }, .expect = .{ .bits = 0x8000_0000 } },
    .{ .encoding = "VRINTN", .name = "-0 stays -0", .input = .{ .a = 0x8000_0000, .rounding = .nearest }, .expect = .{ .bits = 0x8000_0000 } },
    .{ .encoding = "VRINTP", .name = "1.1 rounds up", .input = .{ .a = 0x3F8C_CCCD, .rounding = .plus_inf }, .expect = .{ .bits = 0x4000_0000 } },
    .{ .encoding = "VRINTP", .name = "-0.5 rounds up to -0", .input = .{ .a = 0xBF00_0000, .rounding = .plus_inf }, .expect = .{ .bits = 0x8000_0000 } },
    .{ .encoding = "VRINTP", .name = "-1.9 rounds up to -1", .input = .{ .a = 0xBFF3_3333, .rounding = .plus_inf }, .expect = .{ .bits = 0xBF80_0000 } },
    .{ .encoding = "VRINTP", .name = "a denormal rounds up to 1", .input = .{ .a = 0x0000_0001, .rounding = .plus_inf }, .expect = .{ .bits = 0x3F80_0000 } },
    .{ .encoding = "VRINTM", .name = "1.9 rounds down", .input = .{ .a = 0x3FF3_3333, .rounding = .minus_inf }, .expect = .{ .bits = 0x3F80_0000 } },
    .{ .encoding = "VRINTM", .name = "-1.1 rounds down to -2", .input = .{ .a = 0xBF8C_CCCD, .rounding = .minus_inf }, .expect = .{ .bits = 0xC000_0000 } },
    .{ .encoding = "VRINTM", .name = "0.4 rounds down to +0", .input = .{ .a = 0x3ECC_CCCD, .rounding = .minus_inf }, .expect = .{ .bits = 0x0000_0000 } },
    .{ .encoding = "VRINTM", .name = "FZ: a negative denormal is -0", .input = .{ .a = 0x8000_0001, .rounding = .minus_inf, .fz = 1 }, .expect = .{ .bits = 0x8000_0000, .flags = f.idc } },
    .{ .encoding = "VRINTZ", .name = "-1.9 truncates", .input = .{ .a = 0xBFF3_3333, .rounding = .zero }, .expect = .{ .bits = 0xBF80_0000 } },
    .{ .encoding = "VRINTZ", .name = "1.5 truncates", .input = .{ .a = 0x3FC0_0000, .rounding = .zero }, .expect = .{ .bits = 0x3F80_0000 } },
    .{ .encoding = "VRINTZ", .name = "2^23 + 1 is already integral", .input = .{ .a = 0x4B00_0001, .rounding = .zero }, .expect = .{ .bits = 0x4B00_0001 } },
    .{ .encoding = "VRINTR", .name = "2.5 under RN, no IXC", .input = .{ .a = 0x4020_0000, .rounding = .nearest }, .expect = .{ .bits = 0x4000_0000 } },
    .{ .encoding = "VRINTR", .name = "2.5 under RP", .input = .{ .a = 0x4020_0000, .rounding = .plus_inf }, .expect = .{ .bits = 0x4040_0000 } },
    .{ .encoding = "VRINTX", .name = "2.5 under RN raises IXC", .input = .{ .a = 0x4020_0000, .rounding = .nearest, .exact = true }, .expect = .{ .bits = 0x4000_0000, .flags = f.ixc } },
    .{ .encoding = "VRINTX", .name = "2.0 is exact", .input = .{ .a = 0x4000_0000, .rounding = .nearest, .exact = true }, .expect = .{ .bits = 0x4000_0000 } },
    .{ .encoding = "VRINTX", .name = "0.1 under RZ raises IXC", .input = .{ .a = 0x3DCC_CCCD, .rounding = .zero, .exact = true }, .expect = .{ .bits = 0x0000_0000, .flags = f.ixc } },
    .{ .encoding = "VRINTX", .name = "a denormal under RN is +0 and inexact", .input = .{ .a = 0x0000_0001, .rounding = .nearest, .exact = true }, .expect = .{ .bits = 0x0000_0000, .flags = f.ixc } },
};

pub const rint64 = [_]V64{
    .{ .encoding = "VRINTA", .name = "2.5 ties away", .input = .{ .a = 0x4004_0000_0000_0000, .rounding = .ties_away }, .expect = .{ .bits = 0x4008_0000_0000_0000 } },
    .{ .encoding = "VRINTN", .name = "2.5 ties to even", .input = .{ .a = 0x4004_0000_0000_0000, .rounding = .nearest }, .expect = .{ .bits = 0x4000_0000_0000_0000 } },
    .{ .encoding = "VRINTN", .name = "2^52 - 0.5 ties up to even", .input = .{ .a = 0x432F_FFFF_FFFF_FFFF, .rounding = .nearest }, .expect = .{ .bits = 0x4330_0000_0000_0000 } },
    .{ .encoding = "VRINTP", .name = "2^52 + 1 is already integral", .input = .{ .a = 0x4330_0000_0000_0001, .rounding = .plus_inf }, .expect = .{ .bits = 0x4330_0000_0000_0001 } },
    .{ .encoding = "VRINTM", .name = "-0.5 rounds down to -1", .input = .{ .a = 0xBFE0_0000_0000_0000, .rounding = .minus_inf }, .expect = .{ .bits = 0xBFF0_0000_0000_0000 } },
    .{ .encoding = "VRINTZ", .name = "2^52 - 0.5 truncates", .input = .{ .a = 0x432F_FFFF_FFFF_FFFF, .rounding = .zero }, .expect = .{ .bits = 0x432F_FFFF_FFFF_FFFE } },
    .{ .encoding = "VRINTR", .name = "1.5 under RN", .input = .{ .a = 0x3FF8_0000_0000_0000, .rounding = .nearest }, .expect = .{ .bits = 0x4000_0000_0000_0000 } },
    .{ .encoding = "VRINTX", .name = "-0.5 under RN is -0 and inexact", .input = .{ .a = 0xBFE0_0000_0000_0000, .rounding = .nearest, .exact = true }, .expect = .{ .bits = 0x8000_0000_0000_0000, .flags = f.ixc } },
    .{ .encoding = "VRINTX", .name = "qNaN propagates", .input = .{ .a = 0x7FF8_0000_0000_0001, .rounding = .nearest, .exact = true }, .expect = .{ .bits = 0x7FF8_0000_0000_0001 } },
};

pub const claimed = [_][]const u8{
    "VRINTA",
    "VRINTN",
    "VRINTP",
    "VRINTM",
    "VRINTZ",
    "VRINTR",
    "VRINTX",
};

pub const covered = vector.encodingsOf(case.Integral(u32), case.Result(u32), &rint32) ++
    vector.encodingsOf(case.Integral(u64), case.Result(u64), &rint64);
