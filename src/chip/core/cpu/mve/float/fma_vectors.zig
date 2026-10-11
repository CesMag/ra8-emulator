//! Conformance vectors for the fused MVE floating-point forms in float.zig,
//! worked from the VFMA, VFMS and VFMAS pseudocode in the Arm ARM (DDI0553)
//! under StandardFPSCRValue. Each lane is one FPMulAdd, so the first VFMA
//! lane keeps the 2^-46 an unfused multiply then add would round away.
const vector = @import("../../conformance/vector.zig");
const flag = @import("../../fpu/case.zig").flag;
const float = @import("float.zig");
const Out = @import("vectors.zig").Out;

pub const Operands = struct {
    d: u128,
    n: u128,
    m: u128,
    size: float.Size,
    op: float.Fused,
    mask: u16 = 0xFFFF,
};

const V = vector.Vector(Operands, Out);

pub const vectors = [_]V{
    .{ .encoding = "VFMA.F32 (MVE) T1", .name = "one rounding, 7.0, inf*0 + qNaN, flushed input", .input = .{ .d = 0x3F800000_7FC00001_3F800000_BF800002, .n = 0x00000001_7F800000_40000000_3F800001, .m = 0x3F800000_00000000_40400000_3F800001, .size = .word, .op = .fma }, .expect = .{ .q = 0x3F800000_7FC00000_40E00000_28800000, .flags = flag.ioc | flag.idc } },
    .{ .encoding = "VFMS.F32 (MVE) T1", .name = "7 - 2*3, 0 - 1*1, inactive lanes keep d", .input = .{ .d = 0x55555555_66666666_00000000_40E00000, .n = 0x3F800000_40000000, .m = 0x3F800000_40400000, .size = .word, .op = .fms, .mask = 0x00FF }, .expect = .{ .q = 0x55555555_66666666_BF800000_3F800000 } },
    .{ .encoding = "VFMAS.F32 (MVE) T1", .name = "d*n + scalar", .input = .{ .d = 0x40000000_40000000_40000000_40000000, .n = 0x40400000_40400000_40400000_40400000, .m = 0x3F800000_3F800000_3F800000_3F800000, .size = .word, .op = .fmas }, .expect = .{ .q = 0x40E00000_40E00000_40E00000_40E00000 } },
    .{ .encoding = "VFMA.F16 (MVE) T1", .name = "2*3 + 1, overflow", .input = .{ .d = 0x3C00_3C00_3C00_3C00_3C00_3C00_0000_3C00, .n = 0x4000_4000_4000_4000_4000_4000_7BFF_4000, .m = 0x4200_4200_4200_4200_4200_4200_4000_4200, .size = .half, .op = .fma }, .expect = .{ .q = 0x4700_4700_4700_4700_4700_4700_7C00_4700, .flags = flag.ofc | flag.ixc } },
    .{ .encoding = "VFMS.F16 (MVE) T1", .name = "7 - 2*3", .input = .{ .d = 0x4700_4700_4700_4700_4700_4700_4700_4700, .n = 0x4000_4000_4000_4000_4000_4000_4000_4000, .m = 0x4200_4200_4200_4200_4200_4200_4200_4200, .size = .half, .op = .fms }, .expect = .{ .q = 0x3C00_3C00_3C00_3C00_3C00_3C00_3C00_3C00 } },
    .{ .encoding = "VFMAS.F16 (MVE) T1", .name = "d*n + scalar", .input = .{ .d = 0x4000_4000_4000_4000_4000_4000_4000_4000, .n = 0x4200_4200_4200_4200_4200_4200_4200_4200, .m = 0x3C00_3C00_3C00_3C00_3C00_3C00_3C00_3C00, .size = .half, .op = .fmas }, .expect = .{ .q = 0x4700_4700_4700_4700_4700_4700_4700_4700 } },
};

pub const claimed = [_][]const u8{ "VFMA.F16 (MVE) T1", "VFMA.F32 (MVE) T1", "VFMS.F16 (MVE) T1", "VFMS.F32 (MVE) T1", "VFMAS.F16 (MVE) T1", "VFMAS.F32 (MVE) T1" };

pub const covered = vector.encodingsOf(Operands, Out, &vectors);
