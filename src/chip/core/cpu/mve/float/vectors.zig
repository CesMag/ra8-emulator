//! Conformance vectors for the MVE floating-point lane arithmetic in
//! float.zig, worked from the VADD, VSUB and VMUL (floating-point)
//! pseudocode in the Arm ARM (DDI0553) under StandardFPSCRValue: round to
//! nearest, default NaN, single precision flushed, FZ16 as FPSCR holds it.
//! An input denormal flushed by FZ16 raises no IDC, as FPUnpack has it.
const vector = @import("../../conformance/vector.zig");
const flag = @import("../../fpu/case.zig").flag;
const float = @import("float.zig");

pub const Operands = struct {
    d: u128 = 0,
    a: u128,
    b: u128,
    size: float.Size,
    op: float.Op,
    mask: u16 = 0xFFFF,
    fz16: u1 = 0,
};

/// The destination after the operation, and the cumulative flags raised.
pub const Out = struct { q: u128, flags: u32 = 0 };

const V = vector.Vector(Operands, Out);

pub const vectors = [_]V{
    .{ .encoding = "VADD.F32 (MVE) T1", .name = "3.0, FZ flushes, inf-inf, DN", .input = .{ .a = 0x7FC00001_7F800000_00000001_3F800000, .b = 0x3F800000_FF800000_3F800000_40000000, .size = .word, .op = .add }, .expect = .{ .q = 0x7FC00000_7FC00000_3F800000_40400000, .flags = flag.ioc | flag.idc } },
    .{ .encoding = "VSUB.F32 (MVE) T1", .name = "inactive lanes keep d and raise nothing", .input = .{ .d = 0xAAAAAAAA_BBBBBBBB_CCCCCCCC_DDDDDDDD, .a = 0x3F800000_7F800000_3F800000_40A00000, .b = 0x3F800000_7F800000_3F800000_40400000, .size = .word, .op = .sub, .mask = 0x00FF }, .expect = .{ .q = 0xAAAAAAAA_BBBBBBBB_00000000_40000000 } },
    .{ .encoding = "VMUL.F32 (MVE) T1", .name = "6.0, overflow, flushed tiny result, -0", .input = .{ .a = 0x3F800000_00800000_7F7FFFFF_40000000, .b = 0x80000000_3F000000_40000000_40400000, .size = .word, .op = .mul }, .expect = .{ .q = 0x80000000_00000000_7F800000_40C00000, .flags = flag.ofc | flag.ufc | flag.ixc } },
    .{ .encoding = "VADD.F16 (MVE) T1", .name = "3.0, exact denormal, overflow, inf-inf", .input = .{ .a = 0x3C00_3C00_3C00_3C00_7C00_7BFF_0001_3C00, .b = 0x0000_0000_0000_0000_FC00_7BFF_0001_4000, .size = .half, .op = .add }, .expect = .{ .q = 0x3C00_3C00_3C00_3C00_7E00_7C00_0002_4200, .flags = flag.ioc | flag.ofc | flag.ixc } },
    .{ .encoding = "VADD.F16 (MVE) T1", .name = "FZ16 off keeps the denormal: inexact", .input = .{ .a = 0x0001, .b = 0x3C00, .size = .half, .op = .add }, .expect = .{ .q = 0x3C00, .flags = flag.ixc } },
    .{ .encoding = "VADD.F16 (MVE) T1", .name = "FZ16 flushes the denormal, no IDC", .input = .{ .a = 0x0001, .b = 0x3C00, .size = .half, .op = .add, .fz16 = 1 }, .expect = .{ .q = 0x3C00 } },
    .{ .encoding = "VSUB.F16 (MVE) T1", .name = "3 - 1", .input = .{ .a = 0x4200_4200_4200_4200_4200_4200_4200_4200, .b = 0x3C00_3C00_3C00_3C00_3C00_3C00_3C00_3C00, .size = .half, .op = .sub }, .expect = .{ .q = 0x4000_4000_4000_4000_4000_4000_4000_4000 } },
    .{ .encoding = "VMUL.F16 (MVE) T1", .name = "2 * 3 on two lanes", .input = .{ .d = 0x1111_1111_1111_1111_1111_1111_1111_1111, .a = 0x4000_4000_4000_4000_4000_4000_4000_4000, .b = 0x4200_4200_4200_4200_4200_4200_4200_4200, .size = .half, .op = .mul, .mask = 0x000F }, .expect = .{ .q = 0x1111_1111_1111_1111_1111_1111_4600_4600 } },
};

pub const claimed = [_][]const u8{ "VADD.F16 (MVE) T1", "VADD.F32 (MVE) T1", "VSUB.F16 (MVE) T1", "VSUB.F32 (MVE) T1", "VMUL.F16 (MVE) T1", "VMUL.F32 (MVE) T1" };

pub const covered = vector.encodingsOf(Operands, Out, &vectors);
