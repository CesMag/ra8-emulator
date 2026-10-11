//! Conformance vectors for VMLA, VMLS, VNMLA and VNMLS, worked from FPMul,
//! FPNeg and FPAdd in the Arm ARM (DDI0553): exact results, the rounding
//! of the product before the add, signed zeros under RN and RM, flags from
//! both steps accumulating, NaN priority across the two steps, and FPNeg
//! flipping NaN signs.
const vector = @import("../../conformance/vector.zig");
const case = @import("../case.zig");
const f = case.flag;

pub const V32 = vector.Vector(case.Ternary(u32), case.Result(u32));
pub const V64 = vector.Vector(case.Ternary(u64), case.Result(u64));

pub const mla32 = [_]V32{
    .{ .encoding = "VMLA (floating-point)", .name = "1+2*3", .input = .{ .d = 0x3F80_0000, .n = 0x4000_0000, .m = 0x4040_0000 }, .expect = .{ .bits = 0x40E0_0000 } },
    .{ .encoding = "VMLA (floating-point)", .name = "product rounds before the add", .input = .{ .d = 0xBF80_0000, .n = 0x3F80_0001, .m = 0x3F80_0001, .mode = .plus_inf }, .expect = .{ .bits = 0x34C0_0000, .flags = f.ixc } },
    .{ .encoding = "VMLA (floating-point)", .name = "+0 + 1*-0", .input = .{ .d = 0x0000_0000, .n = 0x3F80_0000, .m = 0x8000_0000 }, .expect = .{ .bits = 0x0000_0000 } },
    .{ .encoding = "VMLA (floating-point)", .name = "-0 + 1*-0", .input = .{ .d = 0x8000_0000, .n = 0x3F80_0000, .m = 0x8000_0000 }, .expect = .{ .bits = 0x8000_0000 } },
    .{ .encoding = "VMLA (floating-point)", .name = "product overflows, then inf-inf", .input = .{ .d = 0xFF80_0000, .n = 0x7F7F_FFFF, .m = 0x7F7F_FFFF }, .expect = .{ .bits = 0x7FC0_0000, .flags = f.ioc | f.ofc | f.ixc } },
    .{ .encoding = "VMLA (floating-point)", .name = "qNaN accumulator beats a quietened product", .input = .{ .d = 0x7FC0_0001, .n = 0x7F80_0002, .m = 0x3F80_0000 }, .expect = .{ .bits = 0x7FC0_0001, .flags = f.ioc } },
    .{ .encoding = "VMLA (floating-point)", .name = "inf*0 gives the default NaN", .input = .{ .d = 0x3F80_0000, .n = 0x7F80_0000, .m = 0x0000_0000 }, .expect = .{ .bits = 0x7FC0_0000, .flags = f.ioc } },
};

pub const mls32 = [_]V32{
    .{ .encoding = "VMLS (floating-point)", .name = "7-2*3", .input = .{ .d = 0x40E0_0000, .n = 0x4000_0000, .m = 0x4040_0000 }, .expect = .{ .bits = 0x3F80_0000 } },
    .{ .encoding = "VMLS (floating-point)", .name = "6-2*3", .input = .{ .d = 0x40C0_0000, .n = 0x4000_0000, .m = 0x4040_0000 }, .expect = .{ .bits = 0x0000_0000 } },
    .{ .encoding = "VMLS (floating-point)", .name = "6-2*3, RM", .input = .{ .d = 0x40C0_0000, .n = 0x4000_0000, .m = 0x4040_0000, .mode = .minus_inf }, .expect = .{ .bits = 0x8000_0000 } },
    .{ .encoding = "VMLS (floating-point)", .name = "a NaN product is negated", .input = .{ .d = 0x3F80_0000, .n = 0x7FC0_0001, .m = 0x3F80_0000 }, .expect = .{ .bits = 0xFFC0_0001 } },
    .{ .encoding = "VMLS (floating-point)", .name = "inf*0 negates the default NaN", .input = .{ .d = 0x3F80_0000, .n = 0x7F80_0000, .m = 0x0000_0000 }, .expect = .{ .bits = 0xFFC0_0000, .flags = f.ioc } },
};

pub const nmla32 = [_]V32{
    .{ .encoding = "VNMLA (floating-point)", .name = "-(1+2*3)", .input = .{ .d = 0x3F80_0000, .n = 0x4000_0000, .m = 0x4040_0000 }, .expect = .{ .bits = 0xC0E0_0000 } },
    .{ .encoding = "VNMLA (floating-point)", .name = "a NaN accumulator is negated", .input = .{ .d = 0x7FC0_0001, .n = 0x3F80_0000, .m = 0x3F80_0000 }, .expect = .{ .bits = 0xFFC0_0001 } },
    .{ .encoding = "VNMLA (floating-point)", .name = "6 - 6 is +0", .input = .{ .d = 0xC0C0_0000, .n = 0x4000_0000, .m = 0x4040_0000 }, .expect = .{ .bits = 0x0000_0000 } },
};

pub const nmls32 = [_]V32{
    .{ .encoding = "VNMLS (floating-point)", .name = "2*3-1", .input = .{ .d = 0x3F80_0000, .n = 0x4000_0000, .m = 0x4040_0000 }, .expect = .{ .bits = 0x40A0_0000 } },
    .{ .encoding = "VNMLS (floating-point)", .name = "2*3-6, RM", .input = .{ .d = 0x40C0_0000, .n = 0x4000_0000, .m = 0x4040_0000, .mode = .minus_inf }, .expect = .{ .bits = 0x8000_0000 } },
    .{ .encoding = "VNMLS (floating-point)", .name = "a negated sNaN accumulator is quietened", .input = .{ .d = 0x7F80_0001, .n = 0x3F80_0000, .m = 0x3F80_0000 }, .expect = .{ .bits = 0xFFC0_0001, .flags = f.ioc } },
};

pub const all64 = [_]V64{
    .{ .encoding = "VMLA (floating-point)", .name = "1+2*3", .input = .{ .d = 0x3FF0_0000_0000_0000, .n = 0x4000_0000_0000_0000, .m = 0x4008_0000_0000_0000 }, .expect = .{ .bits = 0x401C_0000_0000_0000 } },
    .{ .encoding = "VMLS (floating-point)", .name = "7-2*3", .input = .{ .d = 0x401C_0000_0000_0000, .n = 0x4000_0000_0000_0000, .m = 0x4008_0000_0000_0000 }, .expect = .{ .bits = 0x3FF0_0000_0000_0000 } },
    .{ .encoding = "VNMLA (floating-point)", .name = "-(1+2*3)", .input = .{ .d = 0x3FF0_0000_0000_0000, .n = 0x4000_0000_0000_0000, .m = 0x4008_0000_0000_0000 }, .expect = .{ .bits = 0xC01C_0000_0000_0000 } },
    .{ .encoding = "VNMLS (floating-point)", .name = "2*3-1", .input = .{ .d = 0x3FF0_0000_0000_0000, .n = 0x4000_0000_0000_0000, .m = 0x4008_0000_0000_0000 }, .expect = .{ .bits = 0x4014_0000_0000_0000 } },
};

pub const claimed = [_][]const u8{
    "VMLA (floating-point)",
    "VMLS (floating-point)",
    "VNMLA (floating-point)",
    "VNMLS (floating-point)",
};

const T32 = case.Ternary(u32);
const R32 = case.Result(u32);

pub const covered = vector.encodingsOf(T32, R32, &mla32) ++
    vector.encodingsOf(T32, R32, &mls32) ++
    vector.encodingsOf(T32, R32, &nmla32) ++
    vector.encodingsOf(T32, R32, &nmls32) ++
    vector.encodingsOf(case.Ternary(u64), case.Result(u64), &all64);
