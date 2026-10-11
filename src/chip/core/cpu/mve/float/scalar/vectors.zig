//! Conformance vectors for the MVE floating-point by-scalar forms in
//! float_scalar.zig, worked from the Arm ARM (DDI0553) pseudocode under
//! StandardFPSCRValue. For VCMP the expected `q` holds the new VPR.P0.
const vector = @import("../../../conformance/vector.zig");
const flag = @import("../../../fpu/case.zig").flag;
const float = @import("../float.zig");
const Cond = @import("../cmp/cmp.zig").Cond;
const Out = @import("../vectors.zig").Out;

pub const Op = enum { add, sub, mul, fma, fmas, cmp };

pub const Operands = struct {
    d: u128 = 0,
    n: u128,
    rm: u32,
    size: float.Size,
    op: Op,
    cond: Cond = .eq,
    mask: u16 = 0xFFFF,
};

const V = vector.Vector(Operands, Out);

// F32 lanes, low first.
const n_1234: u128 = 0x40800000_40400000_40000000_3F800000;
const n_2345: u128 = 0x40A00000_40800000_40400000_40000000;
const ten: u32 = 0x41200000;
const ones: u128 = 0x11111111_11111111_11111111_11111111;

pub const vectors = [_]V{
    .{ .encoding = "VADD (MVE, floating-point, by scalar) T2", .name = "F32 plus 0.5", .input = .{ .n = n_1234, .rm = 0x3F000000, .size = .word, .op = .add }, .expect = .{ .q = 0x40900000_40600000_40200000_3FC00000 } },
    .{ .encoding = "VSUB (MVE, floating-point, by scalar) T2", .name = "F16 reads only the low half of Rm", .input = .{ .n = 0x0000_0000_0000_3800_4400_4200_4000_3C00, .rm = 0xFFFF3C00, .size = .half, .op = .sub }, .expect = .{ .q = 0xBC00_BC00_BC00_B800_4200_4000_3C00_0000 } },
    .{ .encoding = "VMUL (MVE, floating-point, by scalar) T2", .name = "a lane predicated past its first byte is computed without flags", .input = .{ .d = ones, .n = 0x7F800001, .rm = ten, .size = .word, .op = .mul, .mask = 0x000E }, .expect = .{ .q = 0x11111111_11111111_11111111_7FC00011 } },
    .{ .encoding = "VFMA (MVE, floating-point, by scalar) T1", .name = "d + n * Rm", .input = .{ .d = 0x3F800000_3F800000_3F800000_3F800000, .n = n_2345, .rm = ten, .size = .word, .op = .fma }, .expect = .{ .q = 0x424C0000_42240000_41F80000_41A80000 } },
    .{ .encoding = "VFMAS (MVE, floating-point, by scalar) T1", .name = "d * n + Rm", .input = .{ .d = n_2345, .n = 0x41200000_41200000_41200000_41200000, .rm = 0x3F800000, .size = .word, .op = .fmas }, .expect = .{ .q = 0x424C0000_42240000_41F80000_41A80000 } },
    .{ .encoding = "VCMP (MVE, floating-point, by scalar) T2", .name = "F32 GE signals on a quiet NaN", .input = .{ .n = 0x7FC00000_40400000_40000000_3F800000, .rm = 0x40000000, .size = .word, .op = .cmp, .cond = .ge }, .expect = .{ .q = 0x0FF0, .flags = flag.ioc } },
    .{ .encoding = "VCMP (MVE, floating-point, by scalar) T2", .name = "F16 EQ reads only the low half of Rm", .input = .{ .n = 0x3C00_3C00_3C00_3C00_4000_3C00_3C00_3C00, .rm = 0xABCD3C00, .size = .half, .op = .cmp, .cond = .eq }, .expect = .{ .q = 0xFF3F } },
};

pub const claimed = [_][]const u8{
    "VADD (MVE, floating-point, by scalar) T2", "VSUB (MVE, floating-point, by scalar) T2",  "VMUL (MVE, floating-point, by scalar) T2",
    "VFMA (MVE, floating-point, by scalar) T1", "VFMAS (MVE, floating-point, by scalar) T1", "VCMP (MVE, floating-point, by scalar) T2",
};

pub const covered = vector.encodingsOf(Operands, Out, &vectors);
