//! Conformance vectors for VDIV, worked from FPDiv in the Arm ARM
//! (DDI0553). Finite results were checked against an exact rational model
//! rounded per mode. They cover each rounding mode on a non-terminating
//! quotient, 0/0 and inf/inf, division by zero (DZC) against infinity over
//! zero (no flag), signed zeros and infinities, NaN propagation, overflow,
//! exact and inexact denormal results, and FZ turning a denormal divisor
//! into a zero.
const vector = @import("../../conformance/vector.zig");
const case = @import("../case.zig");
const f = case.flag;

pub const V32 = vector.Vector(case.Binary(u32), case.Result(u32));
pub const V64 = vector.Vector(case.Binary(u64), case.Result(u64));

const one: u32 = 0x3F80_0000;
const three: u32 = 0x4040_0000;

pub const div32 = [_]V32{
    .{ .encoding = "VDIV", .name = "6/3", .input = .{ .a = 0x40C0_0000, .b = three }, .expect = .{ .bits = 0x4000_0000 } },
    .{ .encoding = "VDIV", .name = "1/3, RN", .input = .{ .a = one, .b = three }, .expect = .{ .bits = 0x3EAA_AAAB, .flags = f.ixc } },
    .{ .encoding = "VDIV", .name = "1/3, RZ", .input = .{ .a = one, .b = three, .mode = .zero }, .expect = .{ .bits = 0x3EAA_AAAA, .flags = f.ixc } },
    .{ .encoding = "VDIV", .name = "1/3, RP", .input = .{ .a = one, .b = three, .mode = .plus_inf }, .expect = .{ .bits = 0x3EAA_AAAB, .flags = f.ixc } },
    .{ .encoding = "VDIV", .name = "1/3, RM", .input = .{ .a = one, .b = three, .mode = .minus_inf }, .expect = .{ .bits = 0x3EAA_AAAA, .flags = f.ixc } },
    .{ .encoding = "VDIV", .name = "-1/3, RM", .input = .{ .a = 0xBF80_0000, .b = three, .mode = .minus_inf }, .expect = .{ .bits = 0xBEAA_AAAB, .flags = f.ixc } },
    .{ .encoding = "VDIV", .name = "0/0", .input = .{ .a = 0x0000_0000, .b = 0x8000_0000 }, .expect = .{ .bits = 0x7FC0_0000, .flags = f.ioc } },
    .{ .encoding = "VDIV", .name = "inf/inf", .input = .{ .a = 0x7F80_0000, .b = 0xFF80_0000 }, .expect = .{ .bits = 0x7FC0_0000, .flags = f.ioc } },
    .{ .encoding = "VDIV", .name = "1/+0", .input = .{ .a = one, .b = 0x0000_0000 }, .expect = .{ .bits = 0x7F80_0000, .flags = f.dzc } },
    .{ .encoding = "VDIV", .name = "-1/+0", .input = .{ .a = 0xBF80_0000, .b = 0x0000_0000 }, .expect = .{ .bits = 0xFF80_0000, .flags = f.dzc } },
    .{ .encoding = "VDIV", .name = "1/-0", .input = .{ .a = one, .b = 0x8000_0000 }, .expect = .{ .bits = 0xFF80_0000, .flags = f.dzc } },
    .{ .encoding = "VDIV", .name = "inf/0 has no DZC", .input = .{ .a = 0x7F80_0000, .b = 0x0000_0000 }, .expect = .{ .bits = 0x7F80_0000 } },
    .{ .encoding = "VDIV", .name = "inf/-2", .input = .{ .a = 0x7F80_0000, .b = 0xC000_0000 }, .expect = .{ .bits = 0xFF80_0000 } },
    .{ .encoding = "VDIV", .name = "-0/5", .input = .{ .a = 0x8000_0000, .b = 0x40A0_0000 }, .expect = .{ .bits = 0x8000_0000 } },
    .{ .encoding = "VDIV", .name = "-1/inf", .input = .{ .a = 0xBF80_0000, .b = 0x7F80_0000 }, .expect = .{ .bits = 0x8000_0000 } },
    .{ .encoding = "VDIV", .name = "max/0.5 overflows", .input = .{ .a = 0x7F7F_FFFF, .b = 0x3F00_0000 }, .expect = .{ .bits = 0x7F80_0000, .flags = f.ofc | f.ixc } },
    .{ .encoding = "VDIV", .name = "max/denormal, RZ", .input = .{ .a = 0x7F7F_FFFF, .b = 0x0000_0001, .mode = .zero }, .expect = .{ .bits = 0x7F7F_FFFF, .flags = f.ofc | f.ixc } },
    .{ .encoding = "VDIV", .name = "smallest normal/2 is exact", .input = .{ .a = 0x0080_0000, .b = 0x4000_0000 }, .expect = .{ .bits = 0x0040_0000 } },
    .{ .encoding = "VDIV", .name = "smallest denormal/2, RN", .input = .{ .a = 0x0000_0001, .b = 0x4000_0000 }, .expect = .{ .bits = 0x0000_0000, .flags = f.ufc | f.ixc } },
    .{ .encoding = "VDIV", .name = "smallest denormal/2, RP", .input = .{ .a = 0x0000_0001, .b = 0x4000_0000, .mode = .plus_inf }, .expect = .{ .bits = 0x0000_0001, .flags = f.ufc | f.ixc } },
    .{ .encoding = "VDIV", .name = "denormal/denormal", .input = .{ .a = 0x0000_0003, .b = 0x0000_0001 }, .expect = .{ .bits = three } },
    .{ .encoding = "VDIV", .name = "1/max is an inexact denormal", .input = .{ .a = one, .b = 0x7F7F_FFFF }, .expect = .{ .bits = 0x0020_0000, .flags = f.ufc | f.ixc } },
    .{ .encoding = "VDIV", .name = "qNaN passes through", .input = .{ .a = 0x7FC0_0001, .b = one }, .expect = .{ .bits = 0x7FC0_0001 } },
    .{ .encoding = "VDIV", .name = "sNaN divisor is quietened", .input = .{ .a = one, .b = 0xFF80_0002 }, .expect = .{ .bits = 0xFFC0_0002, .flags = f.ioc } },
    .{ .encoding = "VDIV", .name = "a NaN beats 0/0", .input = .{ .a = 0x0000_0000, .b = 0x7FC0_0003 }, .expect = .{ .bits = 0x7FC0_0003 } },
    .{ .encoding = "VDIV", .name = "FZ makes a denormal divisor zero", .input = .{ .a = one, .b = 0x0000_0001, .fz = 1 }, .expect = .{ .bits = 0x7F80_0000, .flags = f.dzc | f.idc } },
    .{ .encoding = "VDIV", .name = "DN gives the default NaN", .input = .{ .a = 0x7FC0_0001, .b = one, .dn = 1 }, .expect = .{ .bits = 0x7FC0_0000 } },
};

pub const div64 = [_]V64{
    .{ .encoding = "VDIV", .name = "6/3", .input = .{ .a = 0x4018_0000_0000_0000, .b = 0x4008_0000_0000_0000 }, .expect = .{ .bits = 0x4000_0000_0000_0000 } },
    .{ .encoding = "VDIV", .name = "1/3", .input = .{ .a = 0x3FF0_0000_0000_0000, .b = 0x4008_0000_0000_0000 }, .expect = .{ .bits = 0x3FD5_5555_5555_5555, .flags = f.ixc } },
    .{ .encoding = "VDIV", .name = "1/7, RP", .input = .{ .a = 0x3FF0_0000_0000_0000, .b = 0x401C_0000_0000_0000, .mode = .plus_inf }, .expect = .{ .bits = 0x3FC2_4924_9249_2493, .flags = f.ixc } },
    .{ .encoding = "VDIV", .name = "1/0", .input = .{ .a = 0x3FF0_0000_0000_0000, .b = 0 }, .expect = .{ .bits = 0x7FF0_0000_0000_0000, .flags = f.dzc } },
    .{ .encoding = "VDIV", .name = "0/0", .input = .{ .a = 0, .b = 0 }, .expect = .{ .bits = 0x7FF8_0000_0000_0000, .flags = f.ioc } },
    .{ .encoding = "VDIV", .name = "smallest denormal/2", .input = .{ .a = 1, .b = 0x4000_0000_0000_0000 }, .expect = .{ .bits = 0, .flags = f.ufc | f.ixc } },
};

pub const claimed = [_][]const u8{
    "VDIV",
};

pub const covered = vector.encodingsOf(case.Binary(u32), case.Result(u32), &div32) ++
    vector.encodingsOf(case.Binary(u64), case.Result(u64), &div64);
