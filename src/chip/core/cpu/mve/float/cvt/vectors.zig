//! Conformance vectors for the MVE VCVTB and VCVTT half/single conversions
//! in float_cvt.zig, worked from the Arm ARM (DDI0553) pseudocode under
//! StandardFPSCRValue, with AHP kept from FPSCR.
const vector = @import("../../../conformance/vector.zig");
const flag = @import("../../../fpu/case.zig").flag;
const Out = @import("../vectors.zig").Out;

pub const Dir = enum { to_half, from_half };

pub const Operands = struct {
    d: u128 = 0,
    m: u128,
    dir: Dir,
    top: bool,
    mask: u16 = 0xFFFF,
    ahp: u1 = 0,
};

const V = vector.Vector(Operands, Out);

pub const vectors = [_]V{
    .{ .encoding = "VCVTB.F16.F32 (MVE) T1", .name = "1.0, 65520 overflows, FZ flushes, sNaN", .input = .{ .d = 0xAAAAAAAA_AAAAAAAA_AAAAAAAA_AAAAAAAA, .m = 0x7F800001_00000001_477FF000_3F800000, .dir = .to_half, .top = false }, .expect = .{ .q = 0xAAAA7E00_AAAA0000_AAAA7C00_AAAA3C00, .flags = flag.ioc | flag.ofc | flag.ixc | flag.idc } },
    .{ .encoding = "VCVTB.F16.F32 (MVE) T1", .name = "AHP: inf saturates, NaN is zero, exponent 31 is ordinary", .input = .{ .m = 0x3F800000_47800000_7FC00000_7F800000, .dir = .to_half, .top = false, .ahp = 1 }, .expect = .{ .q = 0x00003C00_00007C00_00000000_00007FFF, .flags = flag.ioc } },
    .{ .encoding = "VCVTT.F16.F32 (MVE) T1", .name = "exact half denormal, -2, 0.1 rounds, inactive lane kept", .input = .{ .d = 0x55555555_55555555_55555555_55555555, .m = 0x00000000_3DCCCCCD_C0000000_33800000, .dir = .to_half, .top = true, .mask = 0x0FFF }, .expect = .{ .q = 0x55555555_2E665555_C0005555_00015555, .flags = flag.ixc } },
    .{ .encoding = "VCVTB.F32.F16 (MVE) T1", .name = "1.0, half denormal unflushed, sNaN, -inf", .input = .{ .m = 0x1234FC00_12347D00_12340001_12343C00, .dir = .from_half, .top = false }, .expect = .{ .q = 0xFF800000_7FC00000_33800000_3F800000, .flags = flag.ioc } },
    .{ .encoding = "VCVTT.F32.F16 (MVE) T1", .name = "-2, 65504, inactive lane kept, 0.333", .input = .{ .d = 0x99999999_99999999_99999999_99999999, .m = 0x3555FFFF_8000FFFF_7BFFFFFF_C000FFFF, .dir = .from_half, .top = true, .mask = 0xF0FF }, .expect = .{ .q = 0x3EAAA000_99999999_477FE000_C0000000 } },
};

pub const claimed = [_][]const u8{ "VCVTB.F16.F32 (MVE) T1", "VCVTT.F16.F32 (MVE) T1", "VCVTB.F32.F16 (MVE) T1", "VCVTT.F32.F16 (MVE) T1" };

pub const covered = vector.encodingsOf(Operands, Out, &vectors);
