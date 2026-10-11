//! Conformance vectors for VCVT between single and double precision,
//! worked from FPConvert and FPConvertNaN in the Arm ARM (DDI0553). Finite
//! narrowing results were checked against an exact rounding model per
//! mode. They cover exact widening (denormals included), NaN payloads in
//! both directions, DN, FZ on either side, and narrowing that rounds,
//! overflows and underflows.
const vector = @import("../../conformance/vector.zig");
const case = @import("../case.zig");
const f = case.flag;

pub const Widen = vector.Vector(case.Unary(u32), case.Result(u64));
pub const Narrow = vector.Vector(case.Unary(u64), case.Result(u32));

pub const widen = [_]Widen{
    .{ .encoding = "VCVT (between double-precision and single-precision)", .name = "1.0", .input = .{ .a = 0x3F80_0000 }, .expect = .{ .bits = 0x3FF0_0000_0000_0000 } },
    .{ .encoding = "VCVT (between double-precision and single-precision)", .name = "-0", .input = .{ .a = 0x8000_0000 }, .expect = .{ .bits = 0x8000_0000_0000_0000 } },
    .{ .encoding = "VCVT (between double-precision and single-precision)", .name = "+inf", .input = .{ .a = 0x7F80_0000 }, .expect = .{ .bits = 0x7FF0_0000_0000_0000 } },
    .{ .encoding = "VCVT (between double-precision and single-precision)", .name = "-inf", .input = .{ .a = 0xFF80_0000 }, .expect = .{ .bits = 0xFFF0_0000_0000_0000 } },
    .{ .encoding = "VCVT (between double-precision and single-precision)", .name = "max is exact", .input = .{ .a = 0x7F7F_FFFF }, .expect = .{ .bits = 0x47EF_FFFF_E000_0000 } },
    .{ .encoding = "VCVT (between double-precision and single-precision)", .name = "a denormal widens to a normal", .input = .{ .a = 0x0000_0001 }, .expect = .{ .bits = 0x36A0_0000_0000_0000 } },
    .{ .encoding = "VCVT (between double-precision and single-precision)", .name = "FZ flushes the denormal", .input = .{ .a = 0x8000_0001, .fz = 1 }, .expect = .{ .bits = 0x8000_0000_0000_0000, .flags = f.idc } },
    .{ .encoding = "VCVT (between double-precision and single-precision)", .name = "qNaN payload moves up", .input = .{ .a = 0x7FC0_0001 }, .expect = .{ .bits = 0x7FF8_0000_2000_0000 } },
    .{ .encoding = "VCVT (between double-precision and single-precision)", .name = "negative sNaN is quietened", .input = .{ .a = 0xFF80_0001 }, .expect = .{ .bits = 0xFFF8_0000_2000_0000, .flags = f.ioc } },
    .{ .encoding = "VCVT (between double-precision and single-precision)", .name = "DN gives the default NaN", .input = .{ .a = 0xFFC0_0001, .dn = 1 }, .expect = .{ .bits = 0x7FF8_0000_0000_0000 } },
};

pub const narrow = [_]Narrow{
    .{ .encoding = "VCVT (between double-precision and single-precision)", .name = "1.0", .input = .{ .a = 0x3FF0_0000_0000_0000 }, .expect = .{ .bits = 0x3F80_0000 } },
    .{ .encoding = "VCVT (between double-precision and single-precision)", .name = "-inf", .input = .{ .a = 0xFFF0_0000_0000_0000 }, .expect = .{ .bits = 0xFF80_0000 } },
    .{ .encoding = "VCVT (between double-precision and single-precision)", .name = "-0", .input = .{ .a = 0x8000_0000_0000_0000 }, .expect = .{ .bits = 0x8000_0000 } },
    .{ .encoding = "VCVT (between double-precision and single-precision)", .name = "1/3, RN", .input = .{ .a = 0x3FD5_5555_5555_5555 }, .expect = .{ .bits = 0x3EAA_AAAB, .flags = f.ixc } },
    .{ .encoding = "VCVT (between double-precision and single-precision)", .name = "1/3, RZ", .input = .{ .a = 0x3FD5_5555_5555_5555, .mode = .zero }, .expect = .{ .bits = 0x3EAA_AAAA, .flags = f.ixc } },
    .{ .encoding = "VCVT (between double-precision and single-precision)", .name = "-1/3, RM", .input = .{ .a = 0xBFD5_5555_5555_5555, .mode = .minus_inf }, .expect = .{ .bits = 0xBEAA_AAAB, .flags = f.ixc } },
    .{ .encoding = "VCVT (between double-precision and single-precision)", .name = "1e300 overflows, RN", .input = .{ .a = 0x7E37_E43C_8800_759C }, .expect = .{ .bits = 0x7F80_0000, .flags = f.ofc | f.ixc } },
    .{ .encoding = "VCVT (between double-precision and single-precision)", .name = "1e300 overflows, RZ", .input = .{ .a = 0x7E37_E43C_8800_759C, .mode = .zero }, .expect = .{ .bits = 0x7F7F_FFFF, .flags = f.ofc | f.ixc } },
    .{ .encoding = "VCVT (between double-precision and single-precision)", .name = "max + half ulp rounds up to inf", .input = .{ .a = 0x47EF_FFFF_F000_0000 }, .expect = .{ .bits = 0x7F80_0000, .flags = f.ofc | f.ixc } },
    .{ .encoding = "VCVT (between double-precision and single-precision)", .name = "2^-149 is an exact denormal", .input = .{ .a = 0x36A0_0000_0000_0000 }, .expect = .{ .bits = 0x0000_0001 } },
    .{ .encoding = "VCVT (between double-precision and single-precision)", .name = "2^-150 ties to zero", .input = .{ .a = 0x3690_0000_0000_0000 }, .expect = .{ .bits = 0x0000_0000, .flags = f.ufc | f.ixc } },
    .{ .encoding = "VCVT (between double-precision and single-precision)", .name = "2^-150, RP", .input = .{ .a = 0x3690_0000_0000_0000, .mode = .plus_inf }, .expect = .{ .bits = 0x0000_0001, .flags = f.ufc | f.ixc } },
    .{ .encoding = "VCVT (between double-precision and single-precision)", .name = "FZ flushes a denormal result", .input = .{ .a = 0x36A0_0000_0000_0000, .fz = 1 }, .expect = .{ .bits = 0x0000_0000, .flags = f.ufc } },
    .{ .encoding = "VCVT (between double-precision and single-precision)", .name = "qNaN payload is truncated", .input = .{ .a = 0x7FF8_0000_2000_0000 }, .expect = .{ .bits = 0x7FC0_0001 } },
    .{ .encoding = "VCVT (between double-precision and single-precision)", .name = "low payload bits are dropped", .input = .{ .a = 0x7FF0_0000_0000_0001 }, .expect = .{ .bits = 0x7FC0_0000, .flags = f.ioc } },
    .{ .encoding = "VCVT (between double-precision and single-precision)", .name = "negative sNaN is quietened", .input = .{ .a = 0xFFF0_0000_2000_0000 }, .expect = .{ .bits = 0xFFC0_0001, .flags = f.ioc } },
    .{ .encoding = "VCVT (between double-precision and single-precision)", .name = "DN gives the default NaN", .input = .{ .a = 0xFFF8_0000_2000_0000, .dn = 1 }, .expect = .{ .bits = 0x7FC0_0000 } },
};

pub const claimed = [_][]const u8{
    "VCVT (between double-precision and single-precision)",
};

pub const covered = vector.encodingsOf(case.Unary(u32), case.Result(u64), &widen) ++
    vector.encodingsOf(case.Unary(u64), case.Result(u32), &narrow);
