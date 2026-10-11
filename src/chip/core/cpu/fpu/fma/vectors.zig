//! Conformance vectors for VFMA, VFMS, VFNMA and VFNMS, worked from
//! FPMulAdd and FPNeg in the Arm ARM (DDI0553). Finite results were checked
//! against an exact rational model rounded per mode. They cover the single
//! rounding (where the chained forms would differ), three-way NaN priority,
//! the quiet-NaN addend with infinity times zero, signed zeros, overflow,
//! and terms far enough apart that one only decides the rounding.
const vector = @import("../../conformance/vector.zig");
const case = @import("../case.zig");
const f = case.flag;

pub const V32 = vector.Vector(case.Ternary(u32), case.Result(u32));
pub const V64 = vector.Vector(case.Ternary(u64), case.Result(u64));

const one: u32 = 0x3F80_0000;
const tiny: u32 = 0x0DA2_4260;

pub const fma32 = [_]V32{
    .{ .encoding = "VFMA, VFMS (floating-point)", .name = "1+2*3", .input = .{ .op = .vfma, .d = one, .n = 0x4000_0000, .m = 0x4040_0000 }, .expect = .{ .bits = 0x40E0_0000 } },
    .{ .encoding = "VFMA, VFMS (floating-point)", .name = "one rounding, RN", .input = .{ .op = .vfma, .d = 0xBF80_0000, .n = 0x3F80_0001, .m = 0x3F80_0001 }, .expect = .{ .bits = 0x3480_0000, .flags = f.ixc } },
    .{ .encoding = "VFMA, VFMS (floating-point)", .name = "one rounding, RP", .input = .{ .op = .vfma, .d = 0xBF80_0000, .n = 0x3F80_0001, .m = 0x3F80_0001, .mode = .plus_inf }, .expect = .{ .bits = 0x3480_0001, .flags = f.ixc } },
    .{ .encoding = "VFMA, VFMS (floating-point)", .name = "low product bits survive the cancel", .input = .{ .op = .vfma, .d = 0xBF80_0000, .n = 0x3F80_0001, .m = 0x3F7F_FFFF }, .expect = .{ .bits = 0x337F_FFFE } },
    .{ .encoding = "VFMA, VFMS (floating-point)", .name = "qNaN addend with inf*0", .input = .{ .op = .vfma, .d = 0x7FC0_0001, .n = 0x7F80_0000, .m = 0x0000_0000 }, .expect = .{ .bits = 0x7FC0_0000, .flags = f.ioc } },
    .{ .encoding = "VFMA, VFMS (floating-point)", .name = "1 + inf*0", .input = .{ .op = .vfma, .d = one, .n = 0x7F80_0000, .m = 0x0000_0000 }, .expect = .{ .bits = 0x7FC0_0000, .flags = f.ioc } },
    .{ .encoding = "VFMA, VFMS (floating-point)", .name = "-inf + inf*2", .input = .{ .op = .vfma, .d = 0xFF80_0000, .n = 0x7F80_0000, .m = 0x4000_0000 }, .expect = .{ .bits = 0x7FC0_0000, .flags = f.ioc } },
    .{ .encoding = "VFMA, VFMS (floating-point)", .name = "1 + inf*2", .input = .{ .op = .vfma, .d = one, .n = 0x7F80_0000, .m = 0x4000_0000 }, .expect = .{ .bits = 0x7F80_0000 } },
    .{ .encoding = "VFMA, VFMS (floating-point)", .name = "sNaN addend beats a qNaN factor", .input = .{ .op = .vfma, .d = 0x7F80_0001, .n = 0x7FC0_0002, .m = one }, .expect = .{ .bits = 0x7FC0_0001, .flags = f.ioc } },
    .{ .encoding = "VFMA, VFMS (floating-point)", .name = "sNaN factor beats a qNaN addend", .input = .{ .op = .vfma, .d = 0x7FC0_0001, .n = 0x7F80_0002, .m = one }, .expect = .{ .bits = 0x7FC0_0002, .flags = f.ioc } },
    .{ .encoding = "VFMA, VFMS (floating-point)", .name = "qNaN addend beats a qNaN factor", .input = .{ .op = .vfma, .d = 0x7FC0_0001, .n = 0x7FC0_0002, .m = one }, .expect = .{ .bits = 0x7FC0_0001 } },
    .{ .encoding = "VFMA, VFMS (floating-point)", .name = "+0 + 1*-0", .input = .{ .op = .vfma, .d = 0x0000_0000, .n = one, .m = 0x8000_0000 }, .expect = .{ .bits = 0x0000_0000 } },
    .{ .encoding = "VFMA, VFMS (floating-point)", .name = "+0 + 1*-0, RM", .input = .{ .op = .vfma, .d = 0x0000_0000, .n = one, .m = 0x8000_0000, .mode = .minus_inf }, .expect = .{ .bits = 0x8000_0000 } },
    .{ .encoding = "VFMA, VFMS (floating-point)", .name = "-0 + 1*-0", .input = .{ .op = .vfma, .d = 0x8000_0000, .n = one, .m = 0x8000_0000 }, .expect = .{ .bits = 0x8000_0000 } },
    .{ .encoding = "VFMA, VFMS (floating-point)", .name = "max + max*1 overflows", .input = .{ .op = .vfma, .d = 0x7F7F_FFFF, .n = 0x7F7F_FFFF, .m = one }, .expect = .{ .bits = 0x7F80_0000, .flags = f.ofc | f.ixc } },
    .{ .encoding = "VFMA, VFMS (floating-point)", .name = "FZ flushes a denormal addend", .input = .{ .op = .vfma, .d = 0x0000_0001, .n = one, .m = one, .fz = 1 }, .expect = .{ .bits = one, .flags = f.idc } },
    .{ .encoding = "VFMA, VFMS (floating-point)", .name = "1 + tiny^2, RN", .input = .{ .op = .vfma, .d = one, .n = tiny, .m = tiny }, .expect = .{ .bits = one, .flags = f.ixc } },
    .{ .encoding = "VFMA, VFMS (floating-point)", .name = "1 + tiny^2, RP", .input = .{ .op = .vfma, .d = one, .n = tiny, .m = tiny, .mode = .plus_inf }, .expect = .{ .bits = 0x3F80_0001, .flags = f.ixc } },
    .{ .encoding = "VFMA, VFMS (floating-point)", .name = "denormal + 1*1, RN", .input = .{ .op = .vfma, .d = 0x0000_0001, .n = one, .m = one }, .expect = .{ .bits = one, .flags = f.ixc } },
    .{ .encoding = "VFMA, VFMS (floating-point)", .name = "-denormal + 1*1, RZ", .input = .{ .op = .vfma, .d = 0x8000_0001, .n = one, .m = one, .mode = .zero }, .expect = .{ .bits = 0x3F7F_FFFF, .flags = f.ixc } },
    .{ .encoding = "VFMA, VFMS (floating-point)", .name = "exact denormal result", .input = .{ .op = .vfma, .d = 0x0080_0000, .n = 0x3F00_0000, .m = 0x8080_0000 }, .expect = .{ .bits = 0x0040_0000 } },
};

pub const others32 = [_]V32{
    .{ .encoding = "VFMA, VFMS (floating-point)", .name = "7-2*3", .input = .{ .op = .vfms, .d = 0x40E0_0000, .n = 0x4000_0000, .m = 0x4040_0000 }, .expect = .{ .bits = one } },
    .{ .encoding = "VFMA, VFMS (floating-point)", .name = "low product bits survive the cancel", .input = .{ .op = .vfms, .d = one, .n = 0x3F80_0001, .m = 0x3F7F_FFFF }, .expect = .{ .bits = 0xB37F_FFFE } },
    .{ .encoding = "VFMA, VFMS (floating-point)", .name = "a NaN factor is negated first", .input = .{ .op = .vfms, .d = one, .n = 0x7FC0_0002, .m = one }, .expect = .{ .bits = 0xFFC0_0002 } },
    .{ .encoding = "VFMA, VFMS (floating-point)", .name = "6-2*3, RM", .input = .{ .op = .vfms, .d = 0x40C0_0000, .n = 0x4000_0000, .m = 0x4040_0000, .mode = .minus_inf }, .expect = .{ .bits = 0x8000_0000 } },
    .{ .encoding = "VFNMA", .name = "-1-2*3", .input = .{ .op = .vfnma, .d = one, .n = 0x4000_0000, .m = 0x4040_0000 }, .expect = .{ .bits = 0xC0E0_0000 } },
    .{ .encoding = "VFNMA", .name = "a NaN addend is negated first", .input = .{ .op = .vfnma, .d = 0x7FC0_0001, .n = one, .m = one }, .expect = .{ .bits = 0xFFC0_0001 } },
    .{ .encoding = "VFNMA", .name = "low product bits survive the cancel", .input = .{ .op = .vfnma, .d = 0xBF80_0000, .n = 0x3F80_0001, .m = 0x3F7F_FFFF }, .expect = .{ .bits = 0xB37F_FFFE } },
    .{ .encoding = "VFNMS", .name = "2*3-1", .input = .{ .op = .vfnms, .d = one, .n = 0x4000_0000, .m = 0x4040_0000 }, .expect = .{ .bits = 0x40A0_0000 } },
    .{ .encoding = "VFNMS", .name = "low product bits survive the cancel", .input = .{ .op = .vfnms, .d = one, .n = 0x3F80_0001, .m = 0x3F7F_FFFF }, .expect = .{ .bits = 0x337F_FFFE } },
    .{ .encoding = "VFNMS", .name = "2*3-6, RM", .input = .{ .op = .vfnms, .d = 0x40C0_0000, .n = 0x4000_0000, .m = 0x4040_0000, .mode = .minus_inf }, .expect = .{ .bits = 0x8000_0000 } },
};

pub const all64 = [_]V64{
    .{ .encoding = "VFMA, VFMS (floating-point)", .name = "1+2*3", .input = .{ .op = .vfma, .d = 0x3FF0_0000_0000_0000, .n = 0x4000_0000_0000_0000, .m = 0x4008_0000_0000_0000 }, .expect = .{ .bits = 0x401C_0000_0000_0000 } },
    .{ .encoding = "VFMA, VFMS (floating-point)", .name = "7-2*3", .input = .{ .op = .vfms, .d = 0x401C_0000_0000_0000, .n = 0x4000_0000_0000_0000, .m = 0x4008_0000_0000_0000 }, .expect = .{ .bits = 0x3FF0_0000_0000_0000 } },
    .{ .encoding = "VFNMA", .name = "-1-2*3", .input = .{ .op = .vfnma, .d = 0x3FF0_0000_0000_0000, .n = 0x4000_0000_0000_0000, .m = 0x4008_0000_0000_0000 }, .expect = .{ .bits = 0xC01C_0000_0000_0000 } },
    .{ .encoding = "VFNMS", .name = "2*3-1", .input = .{ .op = .vfnms, .d = 0x3FF0_0000_0000_0000, .n = 0x4000_0000_0000_0000, .m = 0x4008_0000_0000_0000 }, .expect = .{ .bits = 0x4014_0000_0000_0000 } },
    .{ .encoding = "VFMA, VFMS (floating-point)", .name = "low product bits survive the cancel", .input = .{ .op = .vfma, .d = 0xBFF0_0000_0000_0000, .n = 0x3FF0_0000_0000_0001, .m = 0x3FEF_FFFF_FFFF_FFFF }, .expect = .{ .bits = 0x3C9F_FFFF_FFFF_FFFE } },
    .{ .encoding = "VFMA, VFMS (floating-point)", .name = "qNaN addend with inf*0", .input = .{ .op = .vfma, .d = 0x7FF8_0000_0000_0001, .n = 0x7FF0_0000_0000_0000, .m = 0 }, .expect = .{ .bits = 0x7FF8_0000_0000_0000, .flags = f.ioc } },
};

pub const claimed = [_][]const u8{
    "VFMA, VFMS (floating-point)",
    "VFNMA",
    "VFNMS",
};

pub const covered = vector.encodingsOf(case.Ternary(u32), case.Result(u32), &fma32) ++
    vector.encodingsOf(case.Ternary(u32), case.Result(u32), &others32) ++
    vector.encodingsOf(case.Ternary(u64), case.Result(u64), &all64);
