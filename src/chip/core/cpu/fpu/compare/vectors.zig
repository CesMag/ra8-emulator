//! Conformance vectors for VCMP and VCMPE, worked from FPCompare in the Arm
//! ARM (DDI0553). They cover each ordering, signed zeros, infinities,
//! denormals with and without FZ, and which NaNs raise IOC for the quiet
//! (VCMP) and signalling (VCMPE) forms, in both the register and the
//! with-zero encodings.
const vector = @import("../../conformance/vector.zig");
const case = @import("../case.zig");
const c = @import("compare.zig").nzcv;
const f = case.flag;

pub const V32 = vector.Vector(case.Compare(u32), case.Ordering);
pub const V64 = vector.Vector(case.Compare(u64), case.Ordering);

pub const compare32 = [_]V32{
    .{ .encoding = "VCMP", .name = "1 = 1", .input = .{ .a = 0x3F80_0000, .b = 0x3F80_0000 }, .expect = .{ .nzcv = c.equal } },
    .{ .encoding = "VCMP", .name = "1 < 2", .input = .{ .a = 0x3F80_0000, .b = 0x4000_0000 }, .expect = .{ .nzcv = c.less } },
    .{ .encoding = "VCMP", .name = "2 > 1", .input = .{ .a = 0x4000_0000, .b = 0x3F80_0000 }, .expect = .{ .nzcv = c.greater } },
    .{ .encoding = "VCMP", .name = "+0 = -0", .input = .{ .a = 0x0000_0000, .b = 0x8000_0000 }, .expect = .{ .nzcv = c.equal } },
    .{ .encoding = "VCMP", .name = "-1 < 1", .input = .{ .a = 0xBF80_0000, .b = 0x3F80_0000 }, .expect = .{ .nzcv = c.less } },
    .{ .encoding = "VCMP", .name = "-2 < -1", .input = .{ .a = 0xC000_0000, .b = 0xBF80_0000 }, .expect = .{ .nzcv = c.less } },
    .{ .encoding = "VCMP", .name = "-inf < max", .input = .{ .a = 0xFF80_0000, .b = 0x7F7F_FFFF }, .expect = .{ .nzcv = c.less } },
    .{ .encoding = "VCMP", .name = "+inf = +inf", .input = .{ .a = 0x7F80_0000, .b = 0x7F80_0000 }, .expect = .{ .nzcv = c.equal } },
    .{ .encoding = "VCMP", .name = "qNaN is quiet for VCMP", .input = .{ .a = 0x7FC0_0000, .b = 0x3F80_0000 }, .expect = .{ .nzcv = c.unordered } },
    .{ .encoding = "VCMPE", .name = "qNaN signals for VCMPE", .input = .{ .a = 0x7FC0_0000, .b = 0x3F80_0000, .e = 1 }, .expect = .{ .nzcv = c.unordered, .flags = f.ioc } },
    .{ .encoding = "VCMP", .name = "sNaN in a signals", .input = .{ .a = 0x7F80_0001, .b = 0x3F80_0000 }, .expect = .{ .nzcv = c.unordered, .flags = f.ioc } },
    .{ .encoding = "VCMP", .name = "sNaN in b signals", .input = .{ .a = 0x3F80_0000, .b = 0xFF80_0001 }, .expect = .{ .nzcv = c.unordered, .flags = f.ioc } },
    .{ .encoding = "VCMPE", .name = "VCMPE orders like VCMP", .input = .{ .a = 0x4000_0000, .b = 0x3F80_0000, .e = 1 }, .expect = .{ .nzcv = c.greater } },
    .{ .encoding = "VCMP", .name = "a denormal is above zero", .input = .{ .a = 0x0000_0001, .b = 0x0000_0000 }, .expect = .{ .nzcv = c.greater } },
    .{ .encoding = "VCMP", .name = "largest denormal < smallest normal", .input = .{ .a = 0x007F_FFFF, .b = 0x0080_0000 }, .expect = .{ .nzcv = c.less } },
    .{ .encoding = "VCMP", .name = "FZ: a denormal equals zero", .input = .{ .a = 0x0000_0001, .b = 0x0000_0000, .fz = 1 }, .expect = .{ .nzcv = c.equal, .flags = f.idc } },
    .{ .encoding = "VCMP", .name = "FZ: opposite denormals are equal", .input = .{ .a = 0x8000_0001, .b = 0x0000_0002, .fz = 1 }, .expect = .{ .nzcv = c.equal, .flags = f.idc } },
    .{ .encoding = "VCMP", .name = "1 against zero", .input = .{ .a = 0x3F80_0000, .b = 0 }, .expect = .{ .nzcv = c.greater } },
    .{ .encoding = "VCMP", .name = "-1 against zero", .input = .{ .a = 0xBF80_0000, .b = 0 }, .expect = .{ .nzcv = c.less } },
    .{ .encoding = "VCMP", .name = "-0 against zero", .input = .{ .a = 0x8000_0000, .b = 0 }, .expect = .{ .nzcv = c.equal } },
    .{ .encoding = "VCMPE", .name = "qNaN against zero signals", .input = .{ .a = 0xFFC0_0001, .b = 0, .e = 1 }, .expect = .{ .nzcv = c.unordered, .flags = f.ioc } },
    .{ .encoding = "VCMPE", .name = "-inf against zero", .input = .{ .a = 0xFF80_0000, .b = 0, .e = 1 }, .expect = .{ .nzcv = c.less } },
};

pub const compare64 = [_]V64{
    .{ .encoding = "VCMP", .name = "1 = 1", .input = .{ .a = 0x3FF0_0000_0000_0000, .b = 0x3FF0_0000_0000_0000 }, .expect = .{ .nzcv = c.equal } },
    .{ .encoding = "VCMP", .name = "1 < 1+ulp", .input = .{ .a = 0x3FF0_0000_0000_0000, .b = 0x3FF0_0000_0000_0001 }, .expect = .{ .nzcv = c.less } },
    .{ .encoding = "VCMP", .name = "-1 > -2", .input = .{ .a = 0xBFF0_0000_0000_0000, .b = 0xC000_0000_0000_0000 }, .expect = .{ .nzcv = c.greater } },
    .{ .encoding = "VCMP", .name = "qNaN is quiet for VCMP", .input = .{ .a = 0x7FF8_0000_0000_0000, .b = 0 }, .expect = .{ .nzcv = c.unordered } },
    .{ .encoding = "VCMPE", .name = "qNaN signals for VCMPE", .input = .{ .a = 0x3FF0_0000_0000_0000, .b = 0x7FF8_0000_0000_0000, .e = 1 }, .expect = .{ .nzcv = c.unordered, .flags = f.ioc } },
    .{ .encoding = "VCMP", .name = "sNaN signals", .input = .{ .a = 0x7FF0_0000_0000_0001, .b = 0 }, .expect = .{ .nzcv = c.unordered, .flags = f.ioc } },
    .{ .encoding = "VCMP", .name = "denormal against zero", .input = .{ .a = 1, .b = 0 }, .expect = .{ .nzcv = c.greater } },
    .{ .encoding = "VCMPE", .name = "FZ: -denormal against zero", .input = .{ .a = 0x8000_0000_0000_0001, .b = 0, .e = 1, .fz = 1 }, .expect = .{ .nzcv = c.equal, .flags = f.idc } },
};

pub const claimed = [_][]const u8{
    "VCMP",
    "VCMPE",
};

pub const covered = vector.encodingsOf(case.Compare(u32), case.Ordering, &compare32) ++
    vector.encodingsOf(case.Compare(u64), case.Ordering, &compare64);
