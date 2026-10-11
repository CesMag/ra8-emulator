//! Conformance vectors for the MVE integer shifts in src/chip/core/cpu/mve/int/shift/shift.zig, worked
//! from the VSHL, VRSHL, VQSHL, VQRSHL, VSHR and VRSHR pseudocode in the Arm
//! ARM (DDI0553). The register shift operands mix left and right shifts,
//! zero, and amounts at and past the lane width in both directions.
const vector = @import("../../../conformance/vector.zig");
const qreg = @import("../../qreg.zig");
const int = @import("../int.zig");
const shift = @import("shift.zig");

pub const RegCase = struct { a: u128, b: u128, size: qreg.Size, mode: shift.Mode };
pub const ImmCase = struct { a: u128, shift: i8, size: qreg.Size, mode: shift.Mode };

const VReg = vector.Vector(RegCase, int.Sat);
const VImm = vector.Vector(ImmCase, int.Sat);

const a: u128 = 0x80000000_7FFFFFFF_00FF7F80_FFFF0001;
const s: u128 = 0x000000F8_00000001_FF0101F9_02FF0103;
const t: u128 = 0x7F7F7F7F_80808080_FCFC0404_E0E02020;

pub const register = [_]VReg{
    .{ .encoding = "VSHL (vector) T1", .name = "s8", .input = .{ .a = a, .b = s, .size = .byte, .mode = .{} }, .expect = .{ .value = 0x80000000_7FFFFFFE_00FEFEFF_FCFF0008, .saturated = false } },
    .{ .encoding = "VSHL (vector) T1", .name = "u16 right is logical", .input = .{ .a = a, .b = s, .size = .half, .mode = .{ .unsigned = true } }, .expect = .{ .value = 0x80000000_7FFFFFFE_01FE00FF_7FFF0008, .saturated = false } },
    .{ .encoding = "VSHL (vector) T1", .name = "s32 by big amounts", .input = .{ .a = a, .b = t, .size = .word, .mode = .{} }, .expect = .{ .value = 0x0FF7F800_00000000, .saturated = false } },
    .{ .encoding = "VRSHL T1", .name = "s8 rounds", .input = .{ .a = a, .b = s, .size = .byte, .mode = .{ .round = true } }, .expect = .{ .value = 0x80000000_7FFFFFFE_00FEFEFF_FC000008, .saturated = false } },
    .{ .encoding = "VRSHL T1", .name = "u32", .input = .{ .a = a, .b = t, .size = .word, .mode = .{ .unsigned = true, .round = true } }, .expect = .{ .value = 0x0FF7F800_00000000, .saturated = false } },
    .{ .encoding = "VQSHL (vector) T1", .name = "s8 clamps", .input = .{ .a = a, .b = s, .size = .byte, .mode = .{ .saturate = true } }, .expect = .{ .value = 0x80000000_7FFFFFFE_00FE7FFF_FCFF0008, .saturated = true } },
    .{ .encoding = "VQSHL (vector) T1", .name = "u16", .input = .{ .a = a, .b = s, .size = .half, .mode = .{ .unsigned = true, .saturate = true } }, .expect = .{ .value = 0x80000000_7FFFFFFF_01FE00FF_7FFF0008, .saturated = true } },
    .{ .encoding = "VQRSHL T1", .name = "s16", .input = .{ .a = a, .b = s, .size = .half, .mode = .{ .round = true, .saturate = true } }, .expect = .{ .value = 0x80000000_7FFFFFFE_01FE00FF_00000008, .saturated = false } },
    .{ .encoding = "VQRSHL T1", .name = "s32 by big amounts", .input = .{ .a = a, .b = t, .size = .word, .mode = .{ .round = true, .saturate = true } }, .expect = .{ .value = 0x80000000_00000000_0FF7F800_80000000, .saturated = true } },
};

pub const immediate = [_]VImm{
    .{ .encoding = "VSHL (immediate) T1", .name = "i8 #3", .input = .{ .a = a, .shift = 3, .size = .byte, .mode = .{} }, .expect = .{ .value = 0xF8F8F8F8_00F8F800_F8F80008, .saturated = false } },
    .{ .encoding = "VSHL (immediate) T1", .name = "i32 #31", .input = .{ .a = a, .shift = 31, .size = .word, .mode = .{ .unsigned = true } }, .expect = .{ .value = 0x80000000_00000000_80000000, .saturated = false } },
    .{ .encoding = "VSHR T1", .name = "s16 #4", .input = .{ .a = a, .shift = -4, .size = .half, .mode = .{} }, .expect = .{ .value = 0xF8000000_07FFFFFF_000F07F8_FFFF0000, .saturated = false } },
    .{ .encoding = "VSHR T1", .name = "u8 #8 clears", .input = .{ .a = a, .shift = -8, .size = .byte, .mode = .{ .unsigned = true } }, .expect = .{ .value = 0, .saturated = false } },
    .{ .encoding = "VRSHR T1", .name = "s8 #1", .input = .{ .a = a, .shift = -1, .size = .byte, .mode = .{ .round = true } }, .expect = .{ .value = 0xC0000000_40000000_000040C0_00000001, .saturated = false } },
    .{ .encoding = "VRSHR T1", .name = "u32 #32", .input = .{ .a = a, .shift = -32, .size = .word, .mode = .{ .unsigned = true, .round = true } }, .expect = .{ .value = 0x00000001_00000000_00000000_00000001, .saturated = false } },
    .{ .encoding = "VQSHL (immediate) T1", .name = "s16 #1", .input = .{ .a = a, .shift = 1, .size = .half, .mode = .{ .saturate = true } }, .expect = .{ .value = 0x80000000_7FFFFFFE_01FE7FFF_FFFE0002, .saturated = true } },
    .{ .encoding = "VQSHL (immediate) T1", .name = "u8 #7", .input = .{ .a = a, .shift = 7, .size = .byte, .mode = .{ .unsigned = true, .saturate = true } }, .expect = .{ .value = 0xFF000000_FFFFFFFF_00FFFFFF_FFFF0080, .saturated = true } },
};

pub const claimed = [_][]const u8{ "VSHL (vector) T1", "VRSHL T1", "VQSHL (vector) T1", "VQRSHL T1", "VSHL (immediate) T1", "VSHR T1", "VRSHR T1", "VQSHL (immediate) T1" };

pub const covered = vector.encodingsOf(RegCase, int.Sat, &register) ++
    vector.encodingsOf(ImmCase, int.Sat, &immediate);
