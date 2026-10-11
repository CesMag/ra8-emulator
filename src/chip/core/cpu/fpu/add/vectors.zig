//! Conformance vectors for VADD and VSUB, worked from FPAdd and FPSub in the
//! Arm ARM (DDI0553): exact sums, ties under every rounding mode, signed
//! zeros, infinities, NaN propagation and priority, default NaN, overflow,
//! exact denormal results, FZ on input, and operands far enough apart that
//! the smaller one only decides the rounding.
const vector = @import("../../conformance/vector.zig");
const case = @import("../case.zig");
const f = case.flag;

pub const V32 = vector.Vector(case.Binary(u32), case.Result(u32));
pub const V64 = vector.Vector(case.Binary(u64), case.Result(u64));

const tiny: u32 = 0x0DA2_4260;

pub const add32 = [_]V32{
    .{ .encoding = "VADD (floating-point)", .name = "1+1", .input = .{ .a = 0x3F80_0000, .b = 0x3F80_0000 }, .expect = .{ .bits = 0x4000_0000 } },
    .{ .encoding = "VADD (floating-point)", .name = "1.5+0.25", .input = .{ .a = 0x3FC0_0000, .b = 0x3E80_0000 }, .expect = .{ .bits = 0x3FE0_0000 } },
    .{ .encoding = "VADD (floating-point)", .name = "half ulp ties to even", .input = .{ .a = 0x3F80_0000, .b = 0x3380_0000 }, .expect = .{ .bits = 0x3F80_0000, .flags = f.ixc } },
    .{ .encoding = "VADD (floating-point)", .name = "just over half ulp", .input = .{ .a = 0x3F80_0000, .b = 0x3380_0001 }, .expect = .{ .bits = 0x3F80_0001, .flags = f.ixc } },
    .{ .encoding = "VADD (floating-point)", .name = "+0 + -0", .input = .{ .a = 0x0000_0000, .b = 0x8000_0000 }, .expect = .{ .bits = 0x0000_0000 } },
    .{ .encoding = "VADD (floating-point)", .name = "+0 + -0, RM", .input = .{ .a = 0x0000_0000, .b = 0x8000_0000, .mode = .minus_inf }, .expect = .{ .bits = 0x8000_0000 } },
    .{ .encoding = "VADD (floating-point)", .name = "-0 + -0", .input = .{ .a = 0x8000_0000, .b = 0x8000_0000 }, .expect = .{ .bits = 0x8000_0000 } },
    .{ .encoding = "VADD (floating-point)", .name = "inf + -inf", .input = .{ .a = 0x7F80_0000, .b = 0xFF80_0000 }, .expect = .{ .bits = 0x7FC0_0000, .flags = f.ioc } },
    .{ .encoding = "VADD (floating-point)", .name = "inf + 1", .input = .{ .a = 0x7F80_0000, .b = 0x3F80_0000 }, .expect = .{ .bits = 0x7F80_0000 } },
    .{ .encoding = "VADD (floating-point)", .name = "qNaN passes through", .input = .{ .a = 0x7FC0_0001, .b = 0x3F80_0000 }, .expect = .{ .bits = 0x7FC0_0001 } },
    .{ .encoding = "VADD (floating-point)", .name = "sNaN is quietened", .input = .{ .a = 0x3F80_0000, .b = 0x7F80_0001 }, .expect = .{ .bits = 0x7FC0_0001, .flags = f.ioc } },
    .{ .encoding = "VADD (floating-point)", .name = "sNaN beats an earlier qNaN", .input = .{ .a = 0x7FC0_0002, .b = 0xFF80_0003 }, .expect = .{ .bits = 0xFFC0_0003, .flags = f.ioc } },
    .{ .encoding = "VADD (floating-point)", .name = "DN gives the default NaN", .input = .{ .a = 0x7FC0_0001, .b = 0x3F80_0000, .dn = 1 }, .expect = .{ .bits = 0x7FC0_0000 } },
    .{ .encoding = "VADD (floating-point)", .name = "max + max overflows", .input = .{ .a = 0x7F7F_FFFF, .b = 0x7F7F_FFFF }, .expect = .{ .bits = 0x7F80_0000, .flags = f.ofc | f.ixc } },
    .{ .encoding = "VADD (floating-point)", .name = "denormal + denormal exact", .input = .{ .a = 0x0000_0001, .b = 0x0000_0001 }, .expect = .{ .bits = 0x0000_0002 } },
    .{ .encoding = "VADD (floating-point)", .name = "FZ flushes denormal inputs", .input = .{ .a = 0x0000_0001, .b = 0x0000_0001, .fz = 1 }, .expect = .{ .bits = 0x0000_0000, .flags = f.idc } },
    .{ .encoding = "VADD (floating-point)", .name = "1 + tiny, RN", .input = .{ .a = 0x3F80_0000, .b = tiny }, .expect = .{ .bits = 0x3F80_0000, .flags = f.ixc } },
    .{ .encoding = "VADD (floating-point)", .name = "1 + tiny, RP", .input = .{ .a = 0x3F80_0000, .b = tiny, .mode = .plus_inf }, .expect = .{ .bits = 0x3F80_0001, .flags = f.ixc } },
};

pub const sub32 = [_]V32{
    .{ .encoding = "VSUB (floating-point)", .name = "1-1", .input = .{ .a = 0x3F80_0000, .b = 0x3F80_0000 }, .expect = .{ .bits = 0x0000_0000 } },
    .{ .encoding = "VSUB (floating-point)", .name = "1-1, RM", .input = .{ .a = 0x3F80_0000, .b = 0x3F80_0000, .mode = .minus_inf }, .expect = .{ .bits = 0x8000_0000 } },
    .{ .encoding = "VSUB (floating-point)", .name = "-1 - -1", .input = .{ .a = 0xBF80_0000, .b = 0xBF80_0000 }, .expect = .{ .bits = 0x0000_0000 } },
    .{ .encoding = "VSUB (floating-point)", .name = "-0 - +0", .input = .{ .a = 0x8000_0000, .b = 0x0000_0000 }, .expect = .{ .bits = 0x8000_0000 } },
    .{ .encoding = "VSUB (floating-point)", .name = "smallest normal - smallest denormal", .input = .{ .a = 0x0080_0000, .b = 0x0000_0001 }, .expect = .{ .bits = 0x007F_FFFF } },
    .{ .encoding = "VSUB (floating-point)", .name = "inf - inf", .input = .{ .a = 0x7F80_0000, .b = 0x7F80_0000 }, .expect = .{ .bits = 0x7FC0_0000, .flags = f.ioc } },
    .{ .encoding = "VSUB (floating-point)", .name = "1 - -inf", .input = .{ .a = 0x3F80_0000, .b = 0xFF80_0000 }, .expect = .{ .bits = 0x7F80_0000 } },
    .{ .encoding = "VSUB (floating-point)", .name = "NaN keeps its own sign", .input = .{ .a = 0x3F80_0000, .b = 0xFFC0_0001 }, .expect = .{ .bits = 0xFFC0_0001 } },
    .{ .encoding = "VSUB (floating-point)", .name = "1 - tiny, RN", .input = .{ .a = 0x3F80_0000, .b = tiny }, .expect = .{ .bits = 0x3F80_0000, .flags = f.ixc } },
    .{ .encoding = "VSUB (floating-point)", .name = "1 - tiny, RZ", .input = .{ .a = 0x3F80_0000, .b = tiny, .mode = .zero }, .expect = .{ .bits = 0x3F7F_FFFF, .flags = f.ixc } },
};

pub const add64 = [_]V64{
    .{ .encoding = "VADD (floating-point)", .name = "1+1", .input = .{ .a = 0x3FF0_0000_0000_0000, .b = 0x3FF0_0000_0000_0000 }, .expect = .{ .bits = 0x4000_0000_0000_0000 } },
    .{ .encoding = "VADD (floating-point)", .name = "half ulp ties to even", .input = .{ .a = 0x3FF0_0000_0000_0000, .b = 0x3CA0_0000_0000_0000 }, .expect = .{ .bits = 0x3FF0_0000_0000_0000, .flags = f.ixc } },
    .{ .encoding = "VADD (floating-point)", .name = "sNaN is quietened", .input = .{ .a = 0x7FF0_0000_0000_0001, .b = 0 }, .expect = .{ .bits = 0x7FF8_0000_0000_0001, .flags = f.ioc } },
};

pub const sub64 = [_]V64{
    .{ .encoding = "VSUB (floating-point)", .name = "1-1, RM", .input = .{ .a = 0x3FF0_0000_0000_0000, .b = 0x3FF0_0000_0000_0000, .mode = .minus_inf }, .expect = .{ .bits = 0x8000_0000_0000_0000 } },
    .{ .encoding = "VSUB (floating-point)", .name = "inf - inf", .input = .{ .a = 0x7FF0_0000_0000_0000, .b = 0x7FF0_0000_0000_0000 }, .expect = .{ .bits = 0x7FF8_0000_0000_0000, .flags = f.ioc } },
    .{ .encoding = "VSUB (floating-point)", .name = "2 - 0.5", .input = .{ .a = 0x4000_0000_0000_0000, .b = 0x3FE0_0000_0000_0000 }, .expect = .{ .bits = 0x3FF8_0000_0000_0000 } },
};

pub const claimed = [_][]const u8{
    "VADD (floating-point)",
    "VSUB (floating-point)",
};

pub const covered = vector.encodingsOf(case.Binary(u32), case.Result(u32), &add32) ++
    vector.encodingsOf(case.Binary(u32), case.Result(u32), &sub32) ++
    vector.encodingsOf(case.Binary(u64), case.Result(u64), &add64) ++
    vector.encodingsOf(case.Binary(u64), case.Result(u64), &sub64);
