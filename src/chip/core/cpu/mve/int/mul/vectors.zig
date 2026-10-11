//! Conformance vectors for the MVE multiplies in int.mul.zig, worked from
//! the VMULH, VRMULH, VQDMULH, VQRDMULH, VMLA and VMLAS pseudocode in the
//! Arm ARM (DDI0553). The doubling vectors include the most negative value
//! squared, the one case that saturates. The VQ{R}DMLA{S}H vectors come from
//! /workspace/tools/mve_dmlah.py on the lane's box.
const vector = @import("../../../conformance/vector.zig");
const qreg = @import("../../qreg.zig");
const int = @import("../int.zig");
const mul = @import("mul.zig");

pub const HighCase = struct { a: u128, b: u128, size: qreg.Size, high: mul.High };
pub const ScalarCase = struct { da: u128, n: u128, scalar: u32, size: qreg.Size, form: mul.ScalarForm };
pub const DoublingCase = struct { da: u128, n: u128, scalar: u32, size: qreg.Size, form: mul.DoublingForm };

const VHigh = vector.Vector(HighCase, int.Sat);
const VScalar = vector.Vector(ScalarCase, u128);
const VDoubling = vector.Vector(DoublingCase, int.Sat);

const a: u128 = 0x80000000_7FFFFFFF_00FF7F80_FFFF0001;
const b: u128 = 0x80000000_00000001_01017F81_0001FFFF;
const c: u128 = 0x00010002_00030004_FFFEFFFD_7FFF8000;
const d: u128 = 0x11223344_55667788_99AABBCC_DDEEFF00;

pub const high = [_]VHigh{
    .{ .encoding = "VMULH T1", .name = "s8", .input = .{ .a = a, .b = b, .size = .byte, .high = .{} }, .expect = .{ .value = 0x40000000_000000FF_00FF3F3F_00FF00FF, .saturated = false } },
    .{ .encoding = "VMULH T1", .name = "u16", .input = .{ .a = a, .b = c, .size = .half, .high = .{ .unsigned = true } }, .expect = .{ .value = 0x00010003_00FE7F7E_7FFE0000, .saturated = false } },
    .{ .encoding = "VMULH T1", .name = "s32", .input = .{ .a = a, .b = c, .size = .word, .high = .{} }, .expect = .{ .value = 0xFFFF7FFF_00018001_FFFFFF00_FFFF8000, .saturated = false } },
    .{ .encoding = "VRMULH T1", .name = "s16", .input = .{ .a = a, .b = c, .size = .half, .high = .{ .round = true } }, .expect = .{ .value = 0x00010000_0000FFFF_00000000, .saturated = false } },
    .{ .encoding = "VRMULH T1", .name = "u8", .input = .{ .a = a, .b = b, .size = .byte, .high = .{ .unsigned = true, .round = true } }, .expect = .{ .value = 0x40000000_00000001_00013F41_00010001, .saturated = false } },
    .{ .encoding = "VRMULH T1", .name = "s32", .input = .{ .a = a, .b = b, .size = .word, .high = .{ .round = true } }, .expect = .{ .value = 0x40000000_00000000_000100FE_FFFFFFFE, .saturated = false } },
    .{ .encoding = "VQDMULH T1", .name = "s8", .input = .{ .a = a, .b = b, .size = .byte, .high = .{ .double = true } }, .expect = .{ .value = 0x7F000000_000000FF_00FF7E7F_00FF00FF, .saturated = true } },
    .{ .encoding = "VQDMULH T1", .name = "s16", .input = .{ .a = a, .b = c, .size = .half, .high = .{ .double = true } }, .expect = .{ .value = 0xFFFF0000_0002FFFF_FFFFFFFD_FFFFFFFF, .saturated = false } },
    .{ .encoding = "VQDMULH T1", .name = "s32", .input = .{ .a = a, .b = b, .size = .word, .high = .{ .double = true } }, .expect = .{ .value = 0x7FFFFFFF_00000000_000201FC_FFFFFFFC, .saturated = true } },
    .{ .encoding = "VQRDMULH T1", .name = "s16", .input = .{ .a = a, .b = c, .size = .half, .high = .{ .round = true, .double = true } }, .expect = .{ .value = 0xFFFF0000_00030000_0000FFFD_FFFFFFFF, .saturated = false } },
    .{ .encoding = "VQRDMULH T1", .name = "s8", .input = .{ .a = a, .b = c, .size = .byte, .high = .{ .round = true, .double = true } }, .expect = .{ .value = 0x0000FF03_FF000000, .saturated = false } },
    .{ .encoding = "VQRDMULH T1", .name = "s32", .input = .{ .a = c, .b = c, .size = .word, .high = .{ .round = true, .double = true } }, .expect = .{ .value = 0x00000002_00000012_00000002_7FFF0001, .saturated = false } },
};

pub const scalar = [_]VScalar{
    .{ .encoding = "VMLA T1", .name = "i8", .input = .{ .da = d, .n = a, .scalar = 0x103, .size = .byte, .form = .vmla }, .expect = 0x91223344_D2637485_99A7384C_DAEBFF03 },
    .{ .encoding = "VMLA T1", .name = "i16", .input = .{ .da = d, .n = a, .scalar = 0xFFFF8001, .size = .half, .form = .vmla }, .expect = 0x91223344_5565F787_1AA93B4C_5DED7F01 },
    .{ .encoding = "VMLA T1", .name = "i32", .input = .{ .da = d, .n = c, .scalar = 0xFFFFFFFF, .size = .word, .form = .vmla }, .expect = 0x11213342_55637784_99ABBBCF_5DEF7F00 },
    .{ .encoding = "VMLAS T1", .name = "i8", .input = .{ .da = d, .n = a, .scalar = 0x7F, .size = .byte, .form = .vmlas }, .expect = 0xFF7F7F7F_AA1908F7_7FD5447F_A2917F7F },
    .{ .encoding = "VMLAS T1", .name = "i16", .input = .{ .da = d, .n = c, .scalar = 0x1234, .size = .half, .form = .vmlas }, .expect = 0x235678BC_1266F054_DEE0DED0_34461234 },
    .{ .encoding = "VMLAS T1", .name = "i32", .input = .{ .da = d, .n = a, .scalar = 0x80000000, .size = .word, .form = .vmlas }, .expect = 0x80000000_2A998878_18BC1A00_5EEEFF00 },
};

pub const doubling = [_]VDoubling{
    .{ .encoding = "VQDMLAH T1", .name = "s8 saturates", .input = .{ .da = d, .n = a, .scalar = 0x80, .size = .byte, .form = .{} }, .expect = .{ .value = 0x7F223344D667788999AB804CDEEFFFFF, .saturated = true } },
    .{ .encoding = "VQDMLAH T1", .name = "s16", .input = .{ .da = d, .n = c, .scalar = 0x1234, .size = .half, .form = .{} }, .expect = .{ .value = 0x112233445566778899A9BBCBF021ECCC, .saturated = false } },
    .{ .encoding = "VQDMLAH T1", .name = "s32 saturates", .input = .{ .da = d, .n = a, .scalar = 0x80000000, .size = .word, .form = .{} }, .expect = .{ .value = 0x7FFFFFFFD566778998AB3C4CDDEFFEFF, .saturated = true } },
    .{ .encoding = "VQRDMLAH T1", .name = "s8", .input = .{ .da = d, .n = c, .scalar = 0x7F, .size = .byte, .form = .{ .round = true } }, .expect = .{ .value = 0x112333465569778C98A8BAC95BED8000, .saturated = false } },
    .{ .encoding = "VQRDMLAH T1", .name = "s16 most negative scalar", .input = .{ .da = a, .n = a, .scalar = 0x8000, .size = .half, .form = .{ .round = true } }, .expect = .{ .value = 0x00000000000000000000000000000000, .saturated = false } },
    .{ .encoding = "VQRDMLAH T1", .name = "s32", .input = .{ .da = d, .n = c, .scalar = 0x7FFFFFFF, .size = .word, .form = .{ .round = true } }, .expect = .{ .value = 0x112333465569778C99A9BBC95DEE7EFF, .saturated = false } },
    .{ .encoding = "VQDMLASH T1", .name = "s8", .input = .{ .da = d, .n = c, .scalar = 0x55, .size = .byte, .form = .{ .scalar_addend = true } }, .expect = .{ .value = 0x55555556555755515556555632555655, .saturated = false } },
    .{ .encoding = "VQDMLASH T1", .name = "s32 saturates", .input = .{ .da = a, .n = a, .scalar = 0x0, .size = .word, .form = .{ .scalar_addend = true } }, .expect = .{ .value = 0x7FFFFFFF7FFFFFFE0001FDFE00000001, .saturated = true } },
    .{ .encoding = "VQRDMLASH T1", .name = "s16", .input = .{ .da = d, .n = a, .scalar = 0xFFFF8001, .size = .half, .form = .{ .scalar_addend = true, .round = true } }, .expect = .{ .value = 0x80008001D56680008000800080018001, .saturated = true } },
    .{ .encoding = "VQRDMLASH T1", .name = "s8 saturates", .input = .{ .da = a, .n = a, .scalar = 0x7F, .size = .byte, .form = .{ .scalar_addend = true, .round = true } }, .expect = .{ .value = 0x7F7F7F7F7F7F7F7F7F7F7F7F7F7F7F7F, .saturated = true } },
};

pub const claimed = [_][]const u8{ "VMULH T1", "VRMULH T1", "VQDMULH T1", "VQRDMULH T1", "VMLA T1", "VMLAS T1", "VQDMLAH T1", "VQRDMLAH T1", "VQDMLASH T1", "VQRDMLASH T1" };

pub const covered = vector.encodingsOf(HighCase, int.Sat, &high) ++
    vector.encodingsOf(ScalarCase, u128, &scalar) ++
    vector.encodingsOf(DoublingCase, int.Sat, &doubling);
