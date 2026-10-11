//! Conformance vectors for VSRI and VSLI (int_insert.zig) and VQSHLU
//! (int_shift.zig), worked from their pseudocode in the Arm ARM (DDI0553).
//! The insert vectors include the shifts at each end of the range, where
//! VSRI keeps Qd whole and VSLI copies Qm whole.
const vector = @import("../../../conformance/vector.zig");
const qreg = @import("../../qreg.zig");
const int = @import("../int.zig");
const shift_vectors = @import("../shift/vectors.zig");

pub const InsertCase = struct { d: u128, m: u128, size: qreg.Size, n: u6, right: bool };

const VInsert = vector.Vector(InsertCase, u128);
const VImm = vector.Vector(shift_vectors.ImmCase, int.Sat);

const a: u128 = 0x80000000_7FFFFFFF_00FF7F80_FFFF0001;
const d: u128 = 0x11223344_55667788_99AABBCC_DDEEFF00;
const p: u128 = 0x01010101_00000000_00000000_00000101;

pub const inserts = [_]VInsert{
    .{ .encoding = "VSRI T1", .name = "i8 #1", .input = .{ .d = d, .m = a, .size = .byte, .n = 1, .right = true }, .expect = 0x40000000_3F7F7FFF_80FFBFC0_FFFF8000 },
    .{ .encoding = "VSRI T1", .name = "i16 #8", .input = .{ .d = d, .m = a, .size = .half, .n = 8, .right = true }, .expect = 0x11803300_557F77FF_9900BB7F_DDFFFF00 },
    .{ .encoding = "VSRI T1", .name = "i32 #32 keeps Qd", .input = .{ .d = d, .m = a, .size = .word, .n = 32, .right = true }, .expect = 0x11223344_55667788_99AABBCC_DDEEFF00 },
    .{ .encoding = "VSRI T1", .name = "i8 #8 keeps Qd", .input = .{ .d = d, .m = a, .size = .byte, .n = 8, .right = true }, .expect = 0x11223344_55667788_99AABBCC_DDEEFF00 },
    .{ .encoding = "VSLI T1", .name = "i8 #0 copies", .input = .{ .d = d, .m = a, .size = .byte, .n = 0, .right = false }, .expect = 0x80000000_7FFFFFFF_00FF7F80_FFFF0001 },
    .{ .encoding = "VSLI T1", .name = "i16 #4", .input = .{ .d = d, .m = a, .size = .half, .n = 4, .right = false }, .expect = 0x00020004_FFF6FFF8_0FFAF80C_FFFE0010 },
    .{ .encoding = "VSLI T1", .name = "i32 #31", .input = .{ .d = d, .m = a, .size = .word, .n = 31, .right = false }, .expect = 0x11223344_D5667788_19AABBCC_DDEEFF00 },
    .{ .encoding = "VSLI T1", .name = "i8 #7", .input = .{ .d = d, .m = a, .size = .byte, .n = 7, .right = false }, .expect = 0x11223344_D5E6F788_19AABB4C_DDEE7F80 },
};

pub const qshlu = [_]VImm{
    .{ .encoding = "VQSHLU T1", .name = "s8 #1", .input = .{ .a = a, .shift = 1, .size = .byte, .mode = .{ .saturate = true, .saturate_unsigned = true } }, .expect = .{ .value = 0xFE000000_0000FE00_00000002, .saturated = true } },
    .{ .encoding = "VQSHLU T1", .name = "s16 #0 floors negatives", .input = .{ .a = a, .shift = 0, .size = .half, .mode = .{ .saturate = true, .saturate_unsigned = true } }, .expect = .{ .value = 0x7FFF0000_00FF7F80_00000001, .saturated = true } },
    .{ .encoding = "VQSHLU T1", .name = "s32 #1", .input = .{ .a = a, .shift = 1, .size = .word, .mode = .{ .saturate = true, .saturate_unsigned = true } }, .expect = .{ .value = 0xFFFFFFFE_01FEFF00_00000000, .saturated = true } },
    .{ .encoding = "VQSHLU T1", .name = "s8 #7 in range", .input = .{ .a = p, .shift = 7, .size = .byte, .mode = .{ .saturate = true, .saturate_unsigned = true } }, .expect = .{ .value = 0x80808080_00000000_00000000_00008080, .saturated = false } },
};

pub const claimed = [_][]const u8{ "VSRI T1", "VSLI T1", "VQSHLU T1" };

pub const covered = vector.encodingsOf(InsertCase, u128, &inserts) ++
    vector.encodingsOf(shift_vectors.ImmCase, int.Sat, &qshlu);
