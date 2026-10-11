//! Conformance vectors for the MVE reductions in reduce.zig, worked from the
//! VADDV, VADDLV, VMLADAV, VMLSDAV, VMLALDAV and VMLSLDAV pseudocode in the
//! Arm ARM (DDI0553). They cover signed and unsigned lanes, a nonzero
//! accumulator, sums that wrap the destination, and the exchanging forms.
const vector = @import("../../conformance/vector.zig");
const qreg = @import("../qreg.zig");
const reduce = @import("reduce.zig");

pub const SumCase = struct { acc: u64 = 0, a: u128, size: qreg.Size, unsigned: bool = false };
pub const DotCase = struct { acc: u64 = 0, a: u128, b: u128, size: qreg.Size, dual: reduce.Dual = .{} };

const VSum = vector.Vector(SumCase, u64);
const VDot = vector.Vector(DotCase, u64);

const a: u128 = 0x80000000_7FFFFFFF_00FF7F80_FFFF0001;
const b: u128 = 0x80000000_00000001_01017F81_0001FFFF;
const c: u128 = 0x00010002_00030004_FFFEFFFD_7FFF8000;

pub const addv = [_]VSum{
    .{ .encoding = "VADDV T1", .name = "s8", .input = .{ .a = a, .size = .byte }, .expect = 0xFFFF_FFF9 },
    .{ .encoding = "VADDV T1", .name = "u8 accumulates and wraps", .input = .{ .acc = 0xFFFF_FFF0, .a = a, .size = .byte, .unsigned = true }, .expect = 0x7E9 },
    .{ .encoding = "VADDV T1", .name = "s16", .input = .{ .a = a, .size = .half }, .expect = 0x807D },
    .{ .encoding = "VADDV T1", .name = "u32 wraps", .input = .{ .acc = 5, .a = a, .size = .word, .unsigned = true }, .expect = 0xFE_7F85 },
};

pub const addlv = [_]VSum{
    .{ .encoding = "VADDLV T1", .name = "s32", .input = .{ .a = a, .size = .word }, .expect = 0xFE_7F80 },
    .{ .encoding = "VADDLV T1", .name = "u32 accumulates and wraps", .input = .{ .acc = 0xFFFF_FFFF_FFFF_FFFF, .a = a, .size = .word, .unsigned = true }, .expect = 0x2_00FE_7F7F },
};

pub const mladav = [_]VDot{
    .{ .encoding = "VMLADAV T1", .name = "s8", .input = .{ .a = a, .b = b, .size = .byte }, .expect = 0xBE7D },
    .{ .encoding = "VMLADAV T1", .name = "u16", .input = .{ .a = a, .b = c, .size = .half, .dual = .{ .unsigned = true } }, .expect = 0x82_7F7C },
    .{ .encoding = "VMLADAV T1", .name = "s32 accumulates and wraps", .input = .{ .acc = 7, .a = a, .b = c, .size = .word }, .expect = 0x7D7E_0183 },
    .{ .encoding = "VMLADAV T1", .name = "s16 exchanging", .input = .{ .a = a, .b = c, .size = .half, .dual = .{ .exchange = true } }, .expect = 0xFDFB },
    .{ .encoding = "VMLSDAV T1", .name = "s16", .input = .{ .a = a, .b = c, .size = .half, .dual = .{ .subtract = true } }, .expect = 0xFFFD_837C },
    .{ .encoding = "VMLSDAV T1", .name = "s8 exchanging with accumulator", .input = .{ .acc = 0x100, .a = a, .b = b, .size = .byte, .dual = .{ .exchange = true, .subtract = true } }, .expect = 0x81 },
};

pub const mlaldav = [_]VDot{
    .{ .encoding = "VMLALDAV T1", .name = "s32", .input = .{ .a = a, .b = c, .size = .word }, .expect = 0x7F02_7D7E_017C },
    .{ .encoding = "VMLALDAV T1", .name = "u16 accumulates", .input = .{ .acc = 0x1_0000_0000, .a = a, .b = b, .size = .half, .dual = .{ .unsigned = true } }, .expect = 0x1_7F84_BF7C },
    .{ .encoding = "VMLALDAV T1", .name = "s32 exchanging", .input = .{ .a = a, .b = b, .size = .word, .dual = .{ .exchange = true } }, .expect = 0xC000_00FD_7F81_0001 },
    .{ .encoding = "VMLSLDAV T1", .name = "s16", .input = .{ .a = a, .b = c, .size = .half, .dual = .{ .subtract = true } }, .expect = 0xFFFF_FFFF_FFFD_837C },
    .{ .encoding = "VMLSLDAV T1", .name = "s32 exchanging with accumulator", .input = .{ .acc = 1, .a = a, .b = c, .size = .word, .dual = .{ .exchange = true, .subtract = true } }, .expect = 0xFF82_40C3_BFC0_FFFC },
};

pub const claimed = [_][]const u8{ "VADDV T1", "VADDLV T1", "VMLADAV T1", "VMLSDAV T1", "VMLALDAV T1", "VMLSLDAV T1" };

pub const covered = vector.encodingsOf(SumCase, u64, &addv) ++
    vector.encodingsOf(SumCase, u64, &addlv) ++
    vector.encodingsOf(DotCase, u64, &mladav) ++
    vector.encodingsOf(DotCase, u64, &mlaldav);
