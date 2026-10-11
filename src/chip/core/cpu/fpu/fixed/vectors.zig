//! Conformance vectors for VCVT between floating point and fixed point,
//! worked from FPToFixed and FixedToFP in the Arm ARM (DDI0553). They cover
//! 16- and 32-bit integer sides, fbits from 1 to 32, truncation toward
//! zero, saturation at 16 bits (IOC without IXC) and at 32, results
//! extended by signedness, the ignored top half of a 16-bit operand, both
//! rounding directions back to float, NaN, infinity and FZ.
const vector = @import("../../conformance/vector.zig");
const case = @import("../case.zig");
const f = case.flag;

pub const ToFixed32 = vector.Vector(case.Fraction(u32), case.Result(u32));
pub const ToFixed64 = vector.Vector(case.Fraction(u64), case.Result(u32));
pub const FromFixed32 = vector.Vector(case.Fraction(u32), case.Result(u32));
pub const FromFixed64 = vector.Vector(case.Fraction(u32), case.Result(u64));

pub const to_single = [_]ToFixed32{
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "1.5, 1 fraction bit", .input = .{ .a = 0x3FC0_0000, .fbits = 1 }, .expect = .{ .bits = 0x0000_0003 } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "1.25 truncates", .input = .{ .a = 0x3FA0_0000, .fbits = 1 }, .expect = .{ .bits = 0x0000_0002, .flags = f.ixc } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "-1.25 truncates toward zero", .input = .{ .a = 0xBFA0_0000, .fbits = 1 }, .expect = .{ .bits = 0xFFFF_FFFE, .flags = f.ixc } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "1.0 at 31 bits saturates", .input = .{ .a = 0x3F80_0000, .fbits = 31 }, .expect = .{ .bits = 0x7FFF_FFFF, .flags = f.ioc } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "-1.0 at 31 bits is exact", .input = .{ .a = 0xBF80_0000, .fbits = 31 }, .expect = .{ .bits = 0x8000_0000 } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "-0.5 at 32 bits", .input = .{ .a = 0xBF00_0000, .fbits = 32 }, .expect = .{ .bits = 0x8000_0000 } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "a quiet NaN gives 0", .input = .{ .a = 0x7FC0_0000, .fbits = 8 }, .expect = .{ .bits = 0x0000_0000, .flags = f.ioc } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "1.0 at 32 bits saturates", .input = .{ .a = 0x3F80_0000, .fbits = 32, .unsigned = true }, .expect = .{ .bits = 0xFFFF_FFFF, .flags = f.ioc } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "0.75 at 32 bits", .input = .{ .a = 0x3F40_0000, .fbits = 32, .unsigned = true }, .expect = .{ .bits = 0xC000_0000 } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "a negative saturates to 0", .input = .{ .a = 0xBF00_0000, .fbits = 4, .unsigned = true }, .expect = .{ .bits = 0x0000_0000, .flags = f.ioc } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "1.5 at 8 bits", .input = .{ .a = 0x3FC0_0000, .width = 16, .fbits = 8 }, .expect = .{ .bits = 0x0000_0180 } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "-1.5 comes back sign-extended", .input = .{ .a = 0xBFC0_0000, .width = 16, .fbits = 8 }, .expect = .{ .bits = 0xFFFF_FE80 } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "128.0 saturates at 16 bits", .input = .{ .a = 0x4300_0000, .width = 16, .fbits = 8 }, .expect = .{ .bits = 0x0000_7FFF, .flags = f.ioc } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "-128.0 is the 16-bit minimum", .input = .{ .a = 0xC300_0000, .width = 16, .fbits = 8 }, .expect = .{ .bits = 0xFFFF_8000 } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "just above 1 truncates", .input = .{ .a = 0x3F80_0001, .width = 16, .fbits = 8 }, .expect = .{ .bits = 0x0000_0100, .flags = f.ixc } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "inexact overflow raises IOC only", .input = .{ .a = 0x4348_0001, .width = 16, .fbits = 8 }, .expect = .{ .bits = 0x0000_7FFF, .flags = f.ioc } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "255.5 comes back zero-extended", .input = .{ .a = 0x437F_8000, .width = 16, .fbits = 8, .unsigned = true }, .expect = .{ .bits = 0x0000_FF80 } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "256.0 saturates at 16 bits", .input = .{ .a = 0x4380_0000, .width = 16, .fbits = 8, .unsigned = true }, .expect = .{ .bits = 0x0000_FFFF, .flags = f.ioc } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "a negative saturates to 0", .input = .{ .a = 0xBF80_0000, .width = 16, .fbits = 1, .unsigned = true }, .expect = .{ .bits = 0x0000_0000, .flags = f.ioc } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "FZ flushes a denormal", .input = .{ .a = 0x0000_0001, .width = 16, .fbits = 16, .unsigned = true, .fz = 1 }, .expect = .{ .bits = 0x0000_0000, .flags = f.idc } },
};

pub const to_double = [_]ToFixed64{
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "2.5 at 2 bits", .input = .{ .a = 0x4004_0000_0000_0000, .fbits = 2 }, .expect = .{ .bits = 0x0000_000A } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "just above 1 truncates", .input = .{ .a = 0x3FF0_0000_0000_0001, .fbits = 16 }, .expect = .{ .bits = 0x0001_0000, .flags = f.ixc } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "1.5 at 31 bits", .input = .{ .a = 0x3FF8_0000_0000_0000, .fbits = 31, .unsigned = true }, .expect = .{ .bits = 0xC000_0000 } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "-0.25 at 16 bits", .input = .{ .a = 0xBFD0_0000_0000_0000, .width = 16, .fbits = 16 }, .expect = .{ .bits = 0xFFFF_C000 } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "0.5 at 16 bits saturates", .input = .{ .a = 0x3FE0_0000_0000_0000, .width = 16, .fbits = 16 }, .expect = .{ .bits = 0x0000_7FFF, .flags = f.ioc } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "0.5 at 16 bits", .input = .{ .a = 0x3FE0_0000_0000_0000, .width = 16, .fbits = 16, .unsigned = true }, .expect = .{ .bits = 0x0000_8000 } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "+inf saturates", .input = .{ .a = 0x7FF0_0000_0000_0000, .width = 16, .fbits = 4, .unsigned = true }, .expect = .{ .bits = 0x0000_FFFF, .flags = f.ioc } },
};

pub const from_single = [_]FromFixed32{
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "3 at 1 bit is 1.5", .input = .{ .a = 0x0000_0003, .fbits = 1 }, .expect = .{ .bits = 0x3FC0_0000 } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "-1 at 32 bits is -2^-32", .input = .{ .a = 0xFFFF_FFFF, .fbits = 32 }, .expect = .{ .bits = 0xAF80_0000 } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "2^31-1 at 31 bits rounds to 1", .input = .{ .a = 0x7FFF_FFFF, .fbits = 31 }, .expect = .{ .bits = 0x3F80_0000, .flags = f.ixc } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "2^31-1 at 31 bits toward zero", .input = .{ .a = 0x7FFF_FFFF, .fbits = 31, .mode = .zero }, .expect = .{ .bits = 0x3F7F_FFFF, .flags = f.ixc } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "2^32-1 at 32 bits rounds to 1", .input = .{ .a = 0xFFFF_FFFF, .fbits = 32, .unsigned = true }, .expect = .{ .bits = 0x3F80_0000, .flags = f.ixc } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "2^31 at 32 bits is 0.5", .input = .{ .a = 0x8000_0000, .fbits = 32, .unsigned = true }, .expect = .{ .bits = 0x3F00_0000 } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "-128 at 8 bits is -0.5", .input = .{ .a = 0x0000_FF80, .width = 16, .fbits = 8 }, .expect = .{ .bits = 0xBF00_0000 } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "the top 16 bits are ignored", .input = .{ .a = 0xABCD_0180, .width = 16, .fbits = 8 }, .expect = .{ .bits = 0x3FC0_0000 } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "-32768 at 16 bits is -0.5", .input = .{ .a = 0x0000_8000, .width = 16, .fbits = 16 }, .expect = .{ .bits = 0xBF00_0000 } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "65408 at 8 bits is 255.5", .input = .{ .a = 0x0000_FF80, .width = 16, .fbits = 8, .unsigned = true }, .expect = .{ .bits = 0x437F_8000 } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "1 at 16 bits is 2^-16", .input = .{ .a = 0xFFFF_0001, .width = 16, .fbits = 16, .unsigned = true }, .expect = .{ .bits = 0x3780_0000 } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "zero is +0", .input = .{ .a = 0x0001_0000, .width = 16, .fbits = 4, .unsigned = true }, .expect = .{ .bits = 0x0000_0000 } },
};

pub const from_double = [_]FromFixed64{
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "-2 at 1 bit is -1", .input = .{ .a = 0xFFFF_FFFE, .fbits = 1 }, .expect = .{ .bits = 0xBFF0_0000_0000_0000 } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "2^31-1 at 31 bits is exact", .input = .{ .a = 0x7FFF_FFFF, .fbits = 31 }, .expect = .{ .bits = 0x3FEF_FFFF_FFC0_0000 } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "2^32-1 at 32 bits is exact", .input = .{ .a = 0xFFFF_FFFF, .fbits = 32, .unsigned = true }, .expect = .{ .bits = 0x3FEF_FFFF_FFE0_0000 } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "-32767 at 1 bit", .input = .{ .a = 0x0000_8001, .width = 16, .fbits = 1 }, .expect = .{ .bits = 0xC0CF_FFC0_0000_0000 } },
    .{ .encoding = "VCVT (between floating-point and fixed-point)", .name = "65535 at 16 bits", .input = .{ .a = 0x0000_FFFF, .width = 16, .fbits = 16, .unsigned = true }, .expect = .{ .bits = 0x3FEF_FFE0_0000_0000 } },
};

pub const claimed = [_][]const u8{
    "VCVT (between floating-point and fixed-point)",
};

pub const covered = vector.encodingsOf(case.Fraction(u32), case.Result(u32), &to_single) ++
    vector.encodingsOf(case.Fraction(u64), case.Result(u32), &to_double) ++
    vector.encodingsOf(case.Fraction(u32), case.Result(u32), &from_single) ++
    vector.encodingsOf(case.Fraction(u32), case.Result(u64), &from_double);
