//! Conformance vectors for the MVE VMAXNM/VMINNM and VMAXNMA/VMINNMA lane
//! ops in float_minmax.zig, worked from the Arm ARM (DDI0553) FPMaxNum and
//! FPMinNum pseudocode under StandardFPSCRValue.
const vector = @import("../../../conformance/vector.zig");
const flag = @import("../../../fpu/case.zig").flag;
const Which = @import("../../../fpu/minmax/minmax.zig").Which;
const float = @import("../float.zig");
const Out = @import("../vectors.zig").Out;

pub const Operands = struct {
    d: u128 = 0,
    n: u128,
    m: u128,
    size: float.Size,
    which: Which,
    abs: bool = false,
    mask: u16 = 0xFFFF,
};

const V = vector.Vector(Operands, Out);

// F32 lanes, low first: n = 1, -0, qNaN, sNaN; m = 2, +0, 3, 1.
const nans_n: u128 = 0x7F800001_7FC00000_80000000_3F800000;
const nans_m: u128 = 0x3F800000_40400000_00000000_40000000;

pub const vectors = [_]V{
    .{ .encoding = "VMAXNM (MVE) T1", .name = "zeros, a quiet NaN loses, a signalling NaN gives the default NaN", .input = .{ .n = nans_n, .m = nans_m, .size = .word, .which = .max }, .expect = .{ .q = 0x7FC00000_40400000_00000000_40000000, .flags = flag.ioc } },
    .{ .encoding = "VMINNM (MVE) T1", .name = "min of the zeros is -0", .input = .{ .n = nans_n, .m = nans_m, .size = .word, .which = .min }, .expect = .{ .q = 0x7FC00000_40400000_80000000_3F800000, .flags = flag.ioc } },
    .{ .encoding = "VMAXNMA (MVE) T1", .name = "absolute values, FZ flushes a denormal", .input = .{ .n = 0x80000001_80000000_40000000_C0400000, .m = 0x3F000000_00000000_C0A00000_3F800000, .size = .word, .which = .max, .abs = true }, .expect = .{ .q = 0x3F000000_00000000_40A00000_40400000, .flags = flag.idc } },
    .{ .encoding = "VMINNMA (MVE) T1", .name = "F16 absolute values, inactive lanes kept", .input = .{ .d = 0x7777_7777_7777_7777_7777_7777_7777_7777, .n = 0x7E00_FC00_4000_C200, .m = 0xBC00_3C00_C500_3C00, .size = .half, .which = .min, .abs = true, .mask = 0x00FF }, .expect = .{ .q = 0x7777_7777_7777_7777_3C00_3C00_4000_3C00 } },
};

pub const claimed = [_][]const u8{ "VMAXNM (MVE) T1", "VMINNM (MVE) T1", "VMAXNMA (MVE) T1", "VMINNMA (MVE) T1" };

pub const covered = vector.encodingsOf(Operands, Out, &vectors);
