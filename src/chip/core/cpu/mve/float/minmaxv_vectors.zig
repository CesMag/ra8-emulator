//! Conformance vectors for the MVE VMAXNMV/VMINNMV/VMAXNMAV/VMINNMAV
//! reductions in float_minmax.zig, worked from the Arm ARM (DDI0553)
//! FPMaxNum and FPMinNum pseudocode under StandardFPSCRValue.
const vector = @import("../../conformance/vector.zig");
const flag = @import("../../fpu/case.zig").flag;
const Which = @import("../../fpu/minmax/minmax.zig").Which;
const float = @import("float.zig");

pub const Operands = struct {
    ra: u32,
    m: u128,
    size: float.Size,
    which: Which,
    abs: bool = false,
    mask: u16 = 0xFFFF,
};

/// The scalar written back to Rda, and the cumulative flags raised.
pub const Out = struct {
    r: u32,
    flags: u32 = 0,
};

const V = vector.Vector(Operands, Out);

pub const vectors = [_]V{
    .{ .encoding = "VMAXNMV (MVE) T1", .name = "a signalling NaN lane is quietened and loses", .input = .{ .ra = 0x00000000, .m = 0x7F800001_40400000_C0000000_3F800000, .size = .word, .which = .max }, .expect = .{ .r = 0x40400000, .flags = flag.ioc } },
    .{ .encoding = "VMAXNMV (MVE) T1", .name = "F16 signalling NaN scalar", .input = .{ .ra = 0x7D00, .m = 0xBC00_BC00_BC00_BC00_BC00_BC00_BC00_BC00, .size = .half, .which = .max }, .expect = .{ .r = 0xBC00, .flags = flag.ioc } },
    .{ .encoding = "VMINNMV (MVE) T1", .name = "only predicated lanes fold", .input = .{ .ra = 0x40A00000, .m = 0xC1F00000_C1A00000_40000000_C1200000, .size = .word, .which = .min, .mask = 0x00F0 }, .expect = .{ .r = 0x40000000 } },
    .{ .encoding = "VMAXNMAV (MVE) T1", .name = "lanes by magnitude, the scalar as it is", .input = .{ .ra = 0xBF800000, .m = 0x40400000_BF000000_40000000_C0800000, .size = .word, .which = .max, .abs = true }, .expect = .{ .r = 0x40800000 } },
    .{ .encoding = "VMINNMAV (MVE) T1", .name = "F16 reads the low half of Rda and zero-extends", .input = .{ .ra = 0xFFFF7E00, .m = 0x4500_4400_4200_4000_3C00_B400_3800_C200, .size = .half, .which = .min, .abs = true }, .expect = .{ .r = 0x00003400 } },
};

pub const claimed = [_][]const u8{ "VMAXNMV (MVE) T1", "VMINNMV (MVE) T1", "VMAXNMAV (MVE) T1", "VMINNMAV (MVE) T1" };

pub const covered = vector.encodingsOf(Operands, Out, &vectors);
