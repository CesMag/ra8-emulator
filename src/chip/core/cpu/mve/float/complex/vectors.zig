//! Conformance vectors for the MVE complex forms in float_complex.zig
//! (VCADD, VCMLA, VCMUL), worked from the Arm ARM (DDI0553) pseudocode
//! under StandardFPSCRValue.
const vector = @import("../../../conformance/vector.zig");
const flag = @import("../../../fpu/case.zig").flag;
const float = @import("../float.zig");
const Out = @import("../vectors.zig").Out;

pub const Op = enum { cadd, cmla, cmul };

pub const Operands = struct {
    d: u128 = 0,
    n: u128,
    m: u128,
    size: float.Size,
    op: Op,
    /// Rotation in units of 90 degrees; VCADD takes 1 or 3.
    rot: u2,
    mask: u16 = 0xFFFF,
};

const V = vector.Vector(Operands, Out);

// F32 lanes, low first.
const n_add: u128 = 0x40800000_40400000_40000000_3F800000; // 1, 2, 3, 4
const n_mul: u128 = 0x40A00000_40800000_40400000_40000000; // 2, 3, 4, 5
const m_all: u128 = 0x42200000_41F00000_41A00000_41200000; // 10, 20, 30, 40
const d_acc: u128 = 0x3F800000_3F800000_3F000000_3F000000; // 0.5, 0.5, 1, 1
const ones: u128 = 0x7777_7777_7777_7777_7777_7777_7777_7777;

pub const vectors = [_]V{
    .{ .encoding = "VCADD (MVE, floating-point) T1", .name = "rotate 90", .input = .{ .n = n_add, .m = m_all, .size = .word, .op = .cadd, .rot = 1 }, .expect = .{ .q = 0x42080000_C2140000_41400000_C1980000 } },
    .{ .encoding = "VCADD (MVE, floating-point) T1", .name = "rotate 270", .input = .{ .n = n_add, .m = m_all, .size = .word, .op = .cadd, .rot = 3 }, .expect = .{ .q = 0xC1D00000_422C0000_C1000000_41A80000 } },
    .{ .encoding = "VCADD (MVE, floating-point) T1", .name = "F16 inf - inf gives the default NaN", .input = .{ .n = 0x3C00_7C00, .m = 0x7C00_3C00, .size = .half, .op = .cadd, .rot = 1 }, .expect = .{ .q = 0x4000_7E00, .flags = flag.ioc } },
    .{ .encoding = "VCADD (MVE, floating-point) T1", .name = "F16 unpredicated lanes are not computed", .input = .{ .d = ones, .n = 0x4500_3C00_0000_7C00, .m = 0x4000_3C00_FC00_0000, .size = .half, .op = .cadd, .rot = 3, .mask = 0x00F0 }, .expect = .{ .q = 0x7777_7777_7777_7777_4400_4200_7777_7777 } },
    .{ .encoding = "VCMLA (MVE) T1", .name = "rotate 0", .input = .{ .d = d_acc, .n = n_mul, .m = m_all, .size = .word, .op = .cmla, .rot = 0 }, .expect = .{ .q = 0x43210000_42F20000_42220000_41A40000 } },
    .{ .encoding = "VCMLA (MVE) T1", .name = "rotate 90", .input = .{ .d = d_acc, .n = n_mul, .m = m_all, .size = .word, .op = .cmla, .rot = 1 }, .expect = .{ .q = 0x43170000_C3470000_41F40000_C26E0000 } },
    .{ .encoding = "VCMLA (MVE) T1", .name = "rotate 180", .input = .{ .d = d_acc, .n = n_mul, .m = m_all, .size = .word, .op = .cmla, .rot = 2 }, .expect = .{ .q = 0xC31F0000_C2EE0000_C21E0000_C19C0000 } },
    .{ .encoding = "VCMLA (MVE) T1", .name = "rotate 270", .input = .{ .d = d_acc, .n = n_mul, .m = m_all, .size = .word, .op = .cmla, .rot = 3 }, .expect = .{ .q = 0xC3150000_43490000_C1EC0000_42720000 } },
    .{ .encoding = "VCMLA (MVE) T1", .name = "fused: the product is not rounded first", .input = .{ .d = 0xBF800000, .n = 0x3F800800, .m = 0x3F800000_3F800800, .size = .word, .op = .cmla, .rot = 0 }, .expect = .{ .q = 0x3F800800_3A000400 } },
    .{ .encoding = "VCMLA (MVE) T1", .name = "F16 half whose first byte is unpredicated raises no flags", .input = .{ .d = 0x7777_7777_7777_7777_7777_7777_3C00_0000, .n = 0x7C00, .m = 0x4000_0000, .size = .half, .op = .cmla, .rot = 0, .mask = 0x000C }, .expect = .{ .q = 0x7777_7777_7777_7777_7777_7777_7C00_0000 } },
    .{ .encoding = "VCMUL (MVE) T1", .name = "rotate 0 ignores Qd", .input = .{ .d = ones, .n = n_mul, .m = m_all, .size = .word, .op = .cmul, .rot = 0 }, .expect = .{ .q = 0x43200000_42F00000_42200000_41A00000 } },
    .{ .encoding = "VCMUL (MVE) T1", .name = "rotate 90", .input = .{ .n = n_mul, .m = m_all, .size = .word, .op = .cmul, .rot = 1 }, .expect = .{ .q = 0x43160000_C3480000_41F00000_C2700000 } },
    .{ .encoding = "VCMUL (MVE) T1", .name = "rotate 180", .input = .{ .n = n_mul, .m = m_all, .size = .word, .op = .cmul, .rot = 2 }, .expect = .{ .q = 0xC3200000_C2F00000_C2200000_C1A00000 } },
    .{ .encoding = "VCMUL (MVE) T1", .name = "rotate 270", .input = .{ .n = n_mul, .m = m_all, .size = .word, .op = .cmul, .rot = 3 }, .expect = .{ .q = 0xC3160000_43480000_C1F00000_42700000 } },
    .{ .encoding = "VCMUL (MVE) T1", .name = "F16 rotate 90 overflows, zero lanes give -0", .input = .{ .n = 0x5C00_0000, .m = 0x3C00_5C00, .size = .half, .op = .cmul, .rot = 1 }, .expect = .{ .q = 0x0000_8000_0000_8000_0000_8000_7C00_DC00, .flags = flag.ofc | flag.ixc } },
};

pub const claimed = [_][]const u8{ "VCADD (MVE, floating-point) T1", "VCMLA (MVE) T1", "VCMUL (MVE) T1" };

pub const covered = vector.encodingsOf(Operands, Out, &vectors);
