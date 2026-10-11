//! Conformance vectors for VNEG and VABS, worked from FPNeg and FPAbs in the
//! Arm ARM (DDI0553). Inputs cover zeros of both signs, a normal, a denormal,
//! infinities, the default NaN and a signalling NaN, whose payload must come
//! through untouched because neither operation processes NaNs.
const vector = @import("../../conformance/vector.zig");

const V32 = vector.Vector(u32, u32);
const V64 = vector.Vector(u64, u64);

pub const neg32 = [_]V32{
    .{ .encoding = "VNEG (floating-point)", .name = "+0", .input = 0x0000_0000, .expect = 0x8000_0000 },
    .{ .encoding = "VNEG (floating-point)", .name = "-0", .input = 0x8000_0000, .expect = 0x0000_0000 },
    .{ .encoding = "VNEG (floating-point)", .name = "1.0", .input = 0x3F80_0000, .expect = 0xBF80_0000 },
    .{ .encoding = "VNEG (floating-point)", .name = "denormal", .input = 0x0000_0001, .expect = 0x8000_0001 },
    .{ .encoding = "VNEG (floating-point)", .name = "-inf", .input = 0xFF80_0000, .expect = 0x7F80_0000 },
    .{ .encoding = "VNEG (floating-point)", .name = "default NaN", .input = 0x7FC0_0000, .expect = 0xFFC0_0000 },
    .{ .encoding = "VNEG (floating-point)", .name = "sNaN payload kept", .input = 0x7F80_0001, .expect = 0xFF80_0001 },
};

pub const abs32 = [_]V32{
    .{ .encoding = "VABS (floating-point)", .name = "-0", .input = 0x8000_0000, .expect = 0x0000_0000 },
    .{ .encoding = "VABS (floating-point)", .name = "+0", .input = 0x0000_0000, .expect = 0x0000_0000 },
    .{ .encoding = "VABS (floating-point)", .name = "-1.0", .input = 0xBF80_0000, .expect = 0x3F80_0000 },
    .{ .encoding = "VABS (floating-point)", .name = "-inf", .input = 0xFF80_0000, .expect = 0x7F80_0000 },
    .{ .encoding = "VABS (floating-point)", .name = "negative sNaN", .input = 0xFF80_0001, .expect = 0x7F80_0001 },
};

pub const neg64 = [_]V64{
    .{ .encoding = "VNEG (floating-point)", .name = "+0", .input = 0, .expect = 0x8000_0000_0000_0000 },
    .{ .encoding = "VNEG (floating-point)", .name = "1.0", .input = 0x3FF0_0000_0000_0000, .expect = 0xBFF0_0000_0000_0000 },
    .{ .encoding = "VNEG (floating-point)", .name = "denormal", .input = 0x1, .expect = 0x8000_0000_0000_0001 },
    .{ .encoding = "VNEG (floating-point)", .name = "default NaN", .input = 0x7FF8_0000_0000_0000, .expect = 0xFFF8_0000_0000_0000 },
    .{ .encoding = "VNEG (floating-point)", .name = "sNaN payload kept", .input = 0x7FF0_0000_0000_0001, .expect = 0xFFF0_0000_0000_0001 },
};

pub const abs64 = [_]V64{
    .{ .encoding = "VABS (floating-point)", .name = "-0", .input = 0x8000_0000_0000_0000, .expect = 0 },
    .{ .encoding = "VABS (floating-point)", .name = "-1.0", .input = 0xBFF0_0000_0000_0000, .expect = 0x3FF0_0000_0000_0000 },
    .{ .encoding = "VABS (floating-point)", .name = "-inf", .input = 0xFFF0_0000_0000_0000, .expect = 0x7FF0_0000_0000_0000 },
    .{ .encoding = "VABS (floating-point)", .name = "negative sNaN", .input = 0xFFF0_0000_0000_0001, .expect = 0x7FF0_0000_0000_0001 },
};

pub const claimed = [_][]const u8{
    "VNEG (floating-point)",
    "VABS (floating-point)",
};

pub const covered = vector.encodingsOf(u32, u32, &neg32) ++
    vector.encodingsOf(u32, u32, &abs32) ++
    vector.encodingsOf(u64, u64, &neg64) ++
    vector.encodingsOf(u64, u64, &abs64);
