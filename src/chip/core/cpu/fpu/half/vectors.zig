//! Conformance vectors for VCVTB and VCVTT, worked from FPConvert in the
//! Arm ARM (DDI0553). They cover both lanes (the other half kept), the
//! half range edges, overflow per rounding mode, denormals and ties, NaN
//! payloads, DN, FZ on the wide side only, and the alternative half format:
//! exponent 31 as an ordinary binade, saturation and NaNs with IOC alone.
const vector = @import("../../conformance/vector.zig");
const case = @import("../case.zig");
const f = case.flag;

pub const ToHalf32 = vector.Vector(case.Halves(u32), case.Result(u32));
pub const ToHalf64 = vector.Vector(case.Halves(u64), case.Result(u32));
pub const FromHalf32 = vector.Vector(case.Halves(u32), case.Result(u32));
pub const FromHalf64 = vector.Vector(case.Halves(u32), case.Result(u64));

pub const from_single = [_]ToHalf32{
    .{ .encoding = "VCVTB", .name = "1.0 keeps the top half", .input = .{ .a = 0x3F80_0000, .d = 0xABCD_1234 }, .expect = .{ .bits = 0xABCD_3C00 } },
    .{ .encoding = "VCVTT", .name = "1.0 into the top half keeps the bottom", .input = .{ .a = 0x3F80_0000, .top = true, .d = 0x0000_1234 }, .expect = .{ .bits = 0x3C00_1234 } },
    .{ .encoding = "VCVTB", .name = "65504 is the largest half", .input = .{ .a = 0x477F_E000 }, .expect = .{ .bits = 0x0000_7BFF } },
    .{ .encoding = "VCVTB", .name = "65520 overflows to +inf", .input = .{ .a = 0x477F_F000 }, .expect = .{ .bits = 0x0000_7C00, .flags = f.ofc | f.ixc } },
    .{ .encoding = "VCVTB", .name = "65520 toward zero stops at the largest half", .input = .{ .a = 0x477F_F000, .mode = .zero }, .expect = .{ .bits = 0x0000_7BFF, .flags = f.ixc } },
    .{ .encoding = "VCVTB", .name = "2^-24 is the smallest denormal, exact", .input = .{ .a = 0x3380_0000 }, .expect = .{ .bits = 0x0000_0001 } },
    .{ .encoding = "VCVTB", .name = "2^-25 ties to even zero", .input = .{ .a = 0x3300_0000 }, .expect = .{ .bits = 0x0000_0000, .flags = f.ufc | f.ixc } },
    .{ .encoding = "VCVTB", .name = "1+2^-11 ties down to even", .input = .{ .a = 0x3F80_1000 }, .expect = .{ .bits = 0x0000_3C00, .flags = f.ixc } },
    .{ .encoding = "VCVTB", .name = "1+3*2^-11 ties up to even", .input = .{ .a = 0x3F80_3000 }, .expect = .{ .bits = 0x0000_3C02, .flags = f.ixc } },
    .{ .encoding = "VCVTB", .name = "a quiet NaN keeps the top of its payload", .input = .{ .a = 0x7FC1_2345 }, .expect = .{ .bits = 0x0000_7E09 } },
    .{ .encoding = "VCVTB", .name = "an sNaN is quieted and signals", .input = .{ .a = 0xFF80_0001 }, .expect = .{ .bits = 0x0000_FE00, .flags = f.ioc } },
    .{ .encoding = "VCVTB", .name = "DN gives the default NaN", .input = .{ .a = 0x7FC1_2345, .dn = 1 }, .expect = .{ .bits = 0x0000_7E00 } },
    .{ .encoding = "VCVTB", .name = "-inf", .input = .{ .a = 0xFF80_0000 }, .expect = .{ .bits = 0x0000_FC00 } },
    .{ .encoding = "VCVTB", .name = "-0", .input = .{ .a = 0x8000_0000 }, .expect = .{ .bits = 0x0000_8000 } },
    .{ .encoding = "VCVTB", .name = "FZ flushes a single denormal", .input = .{ .a = 0x0000_0001, .fz = 1 }, .expect = .{ .bits = 0x0000_0000, .flags = f.idc } },
    .{ .encoding = "VCVTB", .name = "AHP: 1.0 is unchanged", .input = .{ .a = 0x3F80_0000, .ahp = 1 }, .expect = .{ .bits = 0x0000_3C00 } },
    .{ .encoding = "VCVTB", .name = "AHP: 65536 is exponent 31", .input = .{ .a = 0x4780_0000, .ahp = 1 }, .expect = .{ .bits = 0x0000_7C00 } },
    .{ .encoding = "VCVTB", .name = "AHP: 131008 is the largest", .input = .{ .a = 0x47FF_E000, .ahp = 1 }, .expect = .{ .bits = 0x0000_7FFF } },
    .{ .encoding = "VCVTB", .name = "AHP: 131072 saturates with IOC", .input = .{ .a = 0x4800_0000, .ahp = 1 }, .expect = .{ .bits = 0x0000_7FFF, .flags = f.ioc } },
    .{ .encoding = "VCVTB", .name = "AHP: a tie into overflow saturates, no IXC", .input = .{ .a = 0x47FF_F000, .ahp = 1 }, .expect = .{ .bits = 0x0000_7FFF, .flags = f.ioc } },
    .{ .encoding = "VCVTB", .name = "AHP: 131040 toward zero is inexact", .input = .{ .a = 0x47FF_F000, .ahp = 1, .mode = .zero }, .expect = .{ .bits = 0x0000_7FFF, .flags = f.ixc } },
    .{ .encoding = "VCVTB", .name = "AHP: 65540 rounds in exponent 31", .input = .{ .a = 0x4780_0400, .ahp = 1 }, .expect = .{ .bits = 0x0000_7C00, .flags = f.ixc } },
    .{ .encoding = "VCVTB", .name = "AHP: +inf saturates", .input = .{ .a = 0x7F80_0000, .ahp = 1 }, .expect = .{ .bits = 0x0000_7FFF, .flags = f.ioc } },
    .{ .encoding = "VCVTB", .name = "AHP: -inf saturates negative", .input = .{ .a = 0xFF80_0000, .ahp = 1 }, .expect = .{ .bits = 0x0000_FFFF, .flags = f.ioc } },
    .{ .encoding = "VCVTB", .name = "AHP: a NaN becomes +0", .input = .{ .a = 0x7FC0_0000, .ahp = 1 }, .expect = .{ .bits = 0x0000_0000, .flags = f.ioc } },
    .{ .encoding = "VCVTB", .name = "AHP: a negative NaN becomes -0", .input = .{ .a = 0xFFC0_0000, .ahp = 1 }, .expect = .{ .bits = 0x0000_8000, .flags = f.ioc } },
};

pub const from_double = [_]ToHalf64{
    .{ .encoding = "VCVTB", .name = "1.0", .input = .{ .a = 0x3FF0_0000_0000_0000 }, .expect = .{ .bits = 0x0000_3C00 } },
    .{ .encoding = "VCVTT", .name = "65536 overflows into the top half", .input = .{ .a = 0x40F0_0000_0000_0000, .top = true }, .expect = .{ .bits = 0x7C00_0000, .flags = f.ofc | f.ixc } },
    .{ .encoding = "VCVTB", .name = "just above a tie rounds up", .input = .{ .a = 0x3FF0_0200_0001_0000 }, .expect = .{ .bits = 0x0000_3C01, .flags = f.ixc } },
    .{ .encoding = "VCVTB", .name = "AHP: 65536", .input = .{ .a = 0x40F0_0000_0000_0000, .ahp = 1 }, .expect = .{ .bits = 0x0000_7C00 } },
    .{ .encoding = "VCVTT", .name = "an sNaN is quieted and signals", .input = .{ .a = 0x7FF0_0000_0000_0001, .top = true, .d = 0xFFFF_5555 }, .expect = .{ .bits = 0x7E00_5555, .flags = f.ioc } },
};

pub const to_single = [_]FromHalf32{
    .{ .encoding = "VCVTB", .name = "1.0 from the bottom half", .input = .{ .a = 0x1234_3C00 }, .expect = .{ .bits = 0x3F80_0000 } },
    .{ .encoding = "VCVTT", .name = "-2.0 from the top half", .input = .{ .a = 0xC000_1234, .top = true }, .expect = .{ .bits = 0xC000_0000 } },
    .{ .encoding = "VCVTB", .name = "the smallest denormal", .input = .{ .a = 0x0000_0001 }, .expect = .{ .bits = 0x3380_0000 } },
    .{ .encoding = "VCVTB", .name = "FZ never flushes a half", .input = .{ .a = 0x0000_0001, .fz = 1 }, .expect = .{ .bits = 0x3380_0000 } },
    .{ .encoding = "VCVTB", .name = "65504", .input = .{ .a = 0x0000_7BFF }, .expect = .{ .bits = 0x477F_E000 } },
    .{ .encoding = "VCVTB", .name = "+inf", .input = .{ .a = 0x0000_7C00 }, .expect = .{ .bits = 0x7F80_0000 } },
    .{ .encoding = "VCVTB", .name = "a quiet NaN widens its payload", .input = .{ .a = 0x0000_7E09 }, .expect = .{ .bits = 0x7FC1_2000 } },
    .{ .encoding = "VCVTB", .name = "an sNaN is quieted and signals", .input = .{ .a = 0x0000_7D00 }, .expect = .{ .bits = 0x7FE0_0000, .flags = f.ioc } },
    .{ .encoding = "VCVTB", .name = "DN gives the default NaN", .input = .{ .a = 0x0000_7D00, .dn = 1 }, .expect = .{ .bits = 0x7FC0_0000, .flags = f.ioc } },
    .{ .encoding = "VCVTB", .name = "AHP: exponent 31 is 65536", .input = .{ .a = 0x0000_7C00, .ahp = 1 }, .expect = .{ .bits = 0x4780_0000 } },
    .{ .encoding = "VCVTT", .name = "AHP: the largest", .input = .{ .a = 0x7FFF_0000, .top = true, .ahp = 1 }, .expect = .{ .bits = 0x47FF_E000 } },
    .{ .encoding = "VCVTB", .name = "AHP: the largest negative", .input = .{ .a = 0x0000_FFFF, .ahp = 1 }, .expect = .{ .bits = 0xC7FF_E000 } },
};

pub const to_double = [_]FromHalf64{
    .{ .encoding = "VCVTB", .name = "1.0", .input = .{ .a = 0x0000_3C00 }, .expect = .{ .bits = 0x3FF0_0000_0000_0000 } },
    .{ .encoding = "VCVTT", .name = "65504 from the top half", .input = .{ .a = 0x7BFF_0000, .top = true }, .expect = .{ .bits = 0x40EF_FC00_0000_0000 } },
    .{ .encoding = "VCVTB", .name = "-2^-24", .input = .{ .a = 0x0000_8001 }, .expect = .{ .bits = 0xBE70_0000_0000_0000 } },
    .{ .encoding = "VCVTB", .name = "a quiet NaN widens its payload", .input = .{ .a = 0x0000_7E09 }, .expect = .{ .bits = 0x7FF8_2400_0000_0000 } },
    .{ .encoding = "VCVTT", .name = "AHP: -65536", .input = .{ .a = 0xFC00_0000, .top = true, .ahp = 1 }, .expect = .{ .bits = 0xC0F0_0000_0000_0000 } },
};

pub const claimed = [_][]const u8{
    "VCVTB",
    "VCVTT",
};

pub const covered = vector.encodingsOf(case.Halves(u32), case.Result(u32), &from_single) ++
    vector.encodingsOf(case.Halves(u64), case.Result(u32), &from_double) ++
    vector.encodingsOf(case.Halves(u32), case.Result(u32), &to_single) ++
    vector.encodingsOf(case.Halves(u32), case.Result(u64), &to_double);
