//! Conformance vectors for VMAXNM and VMINNM, worked from FPMaxNum and
//! FPMinNum in the Arm ARM (DDI0553). They cover ordering, signed zeros in
//! both orders, a single quiet NaN losing to any number (infinities
//! included), two quiet NaNs, signalling NaNs winning with IOC, DN, and FZ
//! turning denormals into zeros.
const vector = @import("../../conformance/vector.zig");
const case = @import("../case.zig");
const f = case.flag;

pub const V32 = vector.Vector(case.Binary(u32), case.Result(u32));
pub const V64 = vector.Vector(case.Binary(u64), case.Result(u64));

pub const max32 = [_]V32{
    .{ .encoding = "VMAXNM", .name = "2 over 1", .input = .{ .a = 0x3F80_0000, .b = 0x4000_0000 }, .expect = .{ .bits = 0x4000_0000 } },
    .{ .encoding = "VMAXNM", .name = "-1 over -2", .input = .{ .a = 0xBF80_0000, .b = 0xC000_0000 }, .expect = .{ .bits = 0xBF80_0000 } },
    .{ .encoding = "VMAXNM", .name = "+0 over -0", .input = .{ .a = 0x0000_0000, .b = 0x8000_0000 }, .expect = .{ .bits = 0x0000_0000 } },
    .{ .encoding = "VMAXNM", .name = "+0 over -0, swapped", .input = .{ .a = 0x8000_0000, .b = 0x0000_0000 }, .expect = .{ .bits = 0x0000_0000 } },
    .{ .encoding = "VMAXNM", .name = "two -0 give -0", .input = .{ .a = 0x8000_0000, .b = 0x8000_0000 }, .expect = .{ .bits = 0x8000_0000 } },
    .{ .encoding = "VMAXNM", .name = "a quiet NaN in a loses", .input = .{ .a = 0x7FC0_0000, .b = 0x3F80_0000 }, .expect = .{ .bits = 0x3F80_0000 } },
    .{ .encoding = "VMAXNM", .name = "a quiet NaN in b loses", .input = .{ .a = 0x3F80_0000, .b = 0xFFC0_0000 }, .expect = .{ .bits = 0x3F80_0000 } },
    .{ .encoding = "VMAXNM", .name = "a quiet NaN loses even to -inf", .input = .{ .a = 0x7FC0_0000, .b = 0xFF80_0000 }, .expect = .{ .bits = 0xFF80_0000 } },
    .{ .encoding = "VMAXNM", .name = "two quiet NaNs give the first", .input = .{ .a = 0x7FC0_0001, .b = 0xFFC0_0002 }, .expect = .{ .bits = 0x7FC0_0001 } },
    .{ .encoding = "VMAXNM", .name = "two quiet NaNs under DN", .input = .{ .a = 0x7FC0_0001, .b = 0xFFC0_0002, .dn = 1 }, .expect = .{ .bits = 0x7FC0_0000 } },
    .{ .encoding = "VMAXNM", .name = "an sNaN wins and signals", .input = .{ .a = 0x7F80_0001, .b = 0x3F80_0000 }, .expect = .{ .bits = 0x7FC0_0001, .flags = f.ioc } },
    .{ .encoding = "VMAXNM", .name = "an sNaN beats a quiet NaN", .input = .{ .a = 0x7FC0_0001, .b = 0xFF80_0002 }, .expect = .{ .bits = 0xFFC0_0002, .flags = f.ioc } },
    .{ .encoding = "VMAXNM", .name = "+inf", .input = .{ .a = 0x7F80_0000, .b = 0x3F80_0000 }, .expect = .{ .bits = 0x7F80_0000 } },
    .{ .encoding = "VMAXNM", .name = "a denormal over zero", .input = .{ .a = 0x0000_0001, .b = 0x0000_0000 }, .expect = .{ .bits = 0x0000_0001 } },
    .{ .encoding = "VMAXNM", .name = "FZ: flushed denormals are zeros", .input = .{ .a = 0x0000_0001, .b = 0x8000_0000, .fz = 1 }, .expect = .{ .bits = 0x0000_0000, .flags = f.idc } },
};

pub const min32 = [_]V32{
    .{ .encoding = "VMINNM", .name = "1 under 2", .input = .{ .a = 0x3F80_0000, .b = 0x4000_0000 }, .expect = .{ .bits = 0x3F80_0000 } },
    .{ .encoding = "VMINNM", .name = "-0 under +0", .input = .{ .a = 0x0000_0000, .b = 0x8000_0000 }, .expect = .{ .bits = 0x8000_0000 } },
    .{ .encoding = "VMINNM", .name = "-0 under +0, swapped", .input = .{ .a = 0x8000_0000, .b = 0x0000_0000 }, .expect = .{ .bits = 0x8000_0000 } },
    .{ .encoding = "VMINNM", .name = "a quiet NaN in a loses", .input = .{ .a = 0x7FC0_0000, .b = 0x3F80_0000 }, .expect = .{ .bits = 0x3F80_0000 } },
    .{ .encoding = "VMINNM", .name = "a quiet NaN in b loses", .input = .{ .a = 0x3F80_0000, .b = 0x7FC0_0000 }, .expect = .{ .bits = 0x3F80_0000 } },
    .{ .encoding = "VMINNM", .name = "a quiet NaN loses even to +inf", .input = .{ .a = 0xFFC0_0000, .b = 0x7F80_0000 }, .expect = .{ .bits = 0x7F80_0000 } },
    .{ .encoding = "VMINNM", .name = "an sNaN wins and signals", .input = .{ .a = 0x3F80_0000, .b = 0x7F80_0003 }, .expect = .{ .bits = 0x7FC0_0003, .flags = f.ioc } },
    .{ .encoding = "VMINNM", .name = "-inf", .input = .{ .a = 0xFF80_0000, .b = 0x3F80_0000 }, .expect = .{ .bits = 0xFF80_0000 } },
    .{ .encoding = "VMINNM", .name = "FZ: a flushed -denormal makes -0", .input = .{ .a = 0x8000_0001, .b = 0x0000_0001, .fz = 1 }, .expect = .{ .bits = 0x8000_0000, .flags = f.idc } },
};

pub const max64 = [_]V64{
    .{ .encoding = "VMAXNM", .name = "1.5 over 1", .input = .{ .a = 0x3FF0_0000_0000_0000, .b = 0x3FF8_0000_0000_0000 }, .expect = .{ .bits = 0x3FF8_0000_0000_0000 } },
    .{ .encoding = "VMAXNM", .name = "a quiet NaN loses to -1", .input = .{ .a = 0x7FF8_0000_0000_0000, .b = 0xBFF0_0000_0000_0000 }, .expect = .{ .bits = 0xBFF0_0000_0000_0000 } },
};

pub const min64 = [_]V64{
    .{ .encoding = "VMINNM", .name = "-0 under +0", .input = .{ .a = 0x0000_0000_0000_0000, .b = 0x8000_0000_0000_0000 }, .expect = .{ .bits = 0x8000_0000_0000_0000 } },
    .{ .encoding = "VMINNM", .name = "an sNaN wins and signals", .input = .{ .a = 0x7FF0_0000_0000_0001, .b = 0x0000_0000_0000_0000 }, .expect = .{ .bits = 0x7FF8_0000_0000_0001, .flags = f.ioc } },
};

pub const claimed = [_][]const u8{
    "VMAXNM",
    "VMINNM",
};

pub const covered = vector.encodingsOf(case.Binary(u32), case.Result(u32), &max32) ++
    vector.encodingsOf(case.Binary(u32), case.Result(u32), &min32) ++
    vector.encodingsOf(case.Binary(u64), case.Result(u64), &max64) ++
    vector.encodingsOf(case.Binary(u64), case.Result(u64), &min64);
