//! Conformance vectors for the MVE floating-point VCMP in float_cmp.zig,
//! worked from the Arm ARM (DDI0553) VCMP (floating-point) pseudocode. The
//! result is the VPR.P0 bits, one per byte, for the active lanes.
const vector = @import("../../../conformance/vector.zig");
const flag = @import("../../../fpu/case.zig").flag;
const float = @import("../float.zig");
const float_cmp = @import("cmp.zig");

pub const Operands = struct {
    n: u128,
    m: u128,
    size: float.Size,
    cond: float_cmp.Cond,
    mask: u16 = 0xFFFF,
    fz16: u1 = 0,
};

pub const Out = struct {
    p0: u16,
    flags: u32 = 0,
};

const V = vector.Vector(Operands, Out);

// F32 lanes, low first: 1 vs 1, 2 vs 1, qNaN vs 1, -0 vs +0.
const n32: u128 = 0x80000000_7FC00000_40000000_3F800000;
const m32: u128 = 0x00000000_3F800000_3F800000_3F800000;
// F16 lanes, low first: 1 vs 1, 2 vs 1, qNaN vs 1, -0 vs +0, denormal vs
// +0, 3 vs 4, 3 vs 2, 3 vs 3.
const n16: u128 = 0x4200_4200_4200_0001_8000_7E00_4000_3C00;
const m16: u128 = 0x4200_4000_4400_0000_0000_3C00_3C00_3C00;

pub const vectors = [_]V{
    .{ .encoding = "VCMP.F32 (MVE) T1", .name = "EQ is quiet for a qNaN", .input = .{ .n = n32, .m = m32, .size = .word, .cond = .eq }, .expect = .{ .p0 = 0xF00F } },
    .{ .encoding = "VCMP.F32 (MVE) T1", .name = "NE is true when unordered", .input = .{ .n = n32, .m = m32, .size = .word, .cond = .ne }, .expect = .{ .p0 = 0x0FF0 } },
    .{ .encoding = "VCMP.F32 (MVE) T1", .name = "GE signals on a qNaN", .input = .{ .n = n32, .m = m32, .size = .word, .cond = .ge }, .expect = .{ .p0 = 0xF0FF, .flags = flag.ioc } },
    .{ .encoding = "VCMP.F32 (MVE) T1", .name = "LT is NOT GE, true when unordered", .input = .{ .n = n32, .m = m32, .size = .word, .cond = .lt }, .expect = .{ .p0 = 0x0F00, .flags = flag.ioc } },
    .{ .encoding = "VCMP.F32 (MVE) T1", .name = "GT", .input = .{ .n = n32, .m = m32, .size = .word, .cond = .gt }, .expect = .{ .p0 = 0x00F0, .flags = flag.ioc } },
    .{ .encoding = "VCMP.F32 (MVE) T1", .name = "LE is NOT GT, true when unordered", .input = .{ .n = n32, .m = m32, .size = .word, .cond = .le }, .expect = .{ .p0 = 0xFF0F, .flags = flag.ioc } },
    .{ .encoding = "VCMP.F32 (MVE) T1", .name = "EQ signals an sNaN, inactive lane clear", .input = .{ .n = 0x80000000_7F800001_40000000_3F800000, .m = m32, .size = .word, .cond = .eq, .mask = 0x0FFF }, .expect = .{ .p0 = 0x000F, .flags = flag.ioc } },
    .{ .encoding = "VCMP.F16 (MVE) T1", .name = "GT keeps a half denormal without FZ16", .input = .{ .n = n16, .m = m16, .size = .half, .cond = .gt }, .expect = .{ .p0 = 0x330C, .flags = flag.ioc } },
    .{ .encoding = "VCMP.F16 (MVE) T1", .name = "EQ flushes a half denormal under FZ16, no IDC", .input = .{ .n = n16, .m = m16, .size = .half, .cond = .eq, .fz16 = 1 }, .expect = .{ .p0 = 0xC3C3 } },
};

pub const claimed = [_][]const u8{ "VCMP.F16 (MVE) T1", "VCMP.F32 (MVE) T1" };

pub const covered = vector.encodingsOf(Operands, Out, &vectors);
