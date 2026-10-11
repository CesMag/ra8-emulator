//! Conformance vectors for the MVE narrowing and widening ops in
//! int_width.zig, worked from the VMOVN, VQMOVN, VQMOVUN, VSHRN, VRSHRN,
//! VQSHRN, VQRSHRN, VQSHRUN, VMOVL and VSHLL pseudocode in the Arm ARM
//! (DDI0553). The destination is a distinct byte pattern so a narrowing op
//! that touches the half it should keep shows up.
const vector = @import("../../../conformance/vector.zig");
const qreg = @import("../../qreg.zig");
const int = @import("../int.zig");
const width = @import("width.zig");

pub const NarrowCase = struct { d: u128, m: u128, size: qreg.Size, half: width.Half, spec: width.Narrow };
pub const WidenCase = struct { m: u128, size: qreg.Size, half: width.Half, unsigned: bool, left: u6 };

const VNarrow = vector.Vector(NarrowCase, int.Sat);
const VWiden = vector.Vector(WidenCase, u128);

const a: u128 = 0x80000000_7FFFFFFF_00FF7F80_FFFF0001;
const d: u128 = 0x11223344_55667788_99AABBCC_DDEEFF00;
const m: u128 = 0xFFFF8000_00017FFF_FFFFFF7F_00000080;

pub const narrowing = [_]VNarrow{
    .{ .encoding = "VMOVN T1", .name = "i16 bottom", .input = .{ .d = d, .m = a, .size = .byte, .half = .bottom, .spec = .{} }, .expect = .{ .value = 0x11003300_55FF77FF_99FFBB80_DDFFFF01, .saturated = false } },
    .{ .encoding = "VMOVN T1", .name = "i32 top", .input = .{ .d = d, .m = a, .size = .half, .half = .top, .spec = .{} }, .expect = .{ .value = 0x00003344_FFFF7788_7F80BBCC_0001FF00, .saturated = false } },
    .{ .encoding = "VQMOVN T1", .name = "s16 bottom", .input = .{ .d = d, .m = a, .size = .byte, .half = .bottom, .spec = .{ .saturate = true } }, .expect = .{ .value = 0x11803300_557F77FF_997FBB7F_DDFFFF01, .saturated = true } },
    .{ .encoding = "VQMOVN T1", .name = "u32 top", .input = .{ .d = d, .m = a, .size = .half, .half = .top, .spec = .{ .saturate = true, .in_unsigned = true, .out_unsigned = true } }, .expect = .{ .value = 0xFFFF3344_FFFF7788_FFFFBBCC_FFFFFF00, .saturated = true } },
    .{ .encoding = "VQMOVUN T1", .name = "s16 top", .input = .{ .d = d, .m = a, .size = .byte, .half = .top, .spec = .{ .saturate = true, .out_unsigned = true } }, .expect = .{ .value = 0x00220044_FF660088_FFAAFFCC_00EE0100, .saturated = true } },
    .{ .encoding = "VQMOVUN T1", .name = "s32 bottom", .input = .{ .d = d, .m = m, .size = .half, .half = .bottom, .spec = .{ .saturate = true, .out_unsigned = true } }, .expect = .{ .value = 0x11220000_5566FFFF_99AA0000_DDEE0080, .saturated = true } },
    .{ .encoding = "VSHRN T1", .name = "i16 #4 bottom", .input = .{ .d = d, .m = a, .size = .byte, .half = .bottom, .spec = .{ .shift = 4 } }, .expect = .{ .value = 0x11003300_55FF77FF_990FBBF8_DDFFFF00, .saturated = false } },
    .{ .encoding = "VSHRN T1", .name = "i32 #16 top", .input = .{ .d = d, .m = m, .size = .half, .half = .top, .spec = .{ .shift = 16 } }, .expect = .{ .value = 0xFFFF3344_00017788_FFFFBBCC_0000FF00, .saturated = false } },
    .{ .encoding = "VRSHRN T1", .name = "i16 #1 top", .input = .{ .d = d, .m = a, .size = .byte, .half = .top, .spec = .{ .shift = 1, .round = true } }, .expect = .{ .value = 0x00220044_00660088_80AAC0CC_00EE0100, .saturated = false } },
    .{ .encoding = "VRSHRN T1", .name = "i32 #8 bottom", .input = .{ .d = d, .m = m, .size = .half, .half = .bottom, .spec = .{ .shift = 8, .round = true } }, .expect = .{ .value = 0x1122FF80_55660180_99AAFFFF_DDEE0001, .saturated = false } },
    .{ .encoding = "VQSHRN T1", .name = "s16 #1 bottom", .input = .{ .d = d, .m = a, .size = .byte, .half = .bottom, .spec = .{ .shift = 1, .saturate = true } }, .expect = .{ .value = 0x11803300_557F77FF_997FBB7F_DDFFFF00, .saturated = true } },
    .{ .encoding = "VQSHRN T1", .name = "u32 #4 top", .input = .{ .d = d, .m = m, .size = .half, .half = .top, .spec = .{ .shift = 4, .saturate = true, .in_unsigned = true, .out_unsigned = true } }, .expect = .{ .value = 0xFFFF3344_17FF7788_FFFFBBCC_0008FF00, .saturated = true } },
    .{ .encoding = "VQRSHRN T1", .name = "s32 #8 top", .input = .{ .d = d, .m = m, .size = .half, .half = .top, .spec = .{ .shift = 8, .round = true, .saturate = true } }, .expect = .{ .value = 0xFF803344_01807788_FFFFBBCC_0001FF00, .saturated = false } },
    .{ .encoding = "VQRSHRN T1", .name = "u16 #7 bottom", .input = .{ .d = d, .m = a, .size = .byte, .half = .bottom, .spec = .{ .shift = 7, .round = true, .saturate = true, .in_unsigned = true, .out_unsigned = true } }, .expect = .{ .value = 0x11FF3300_55FF77FF_9902BBFF_DDFFFF00, .saturated = true } },
    .{ .encoding = "VQSHRUN T1", .name = "s16 #2 bottom", .input = .{ .d = d, .m = a, .size = .byte, .half = .bottom, .spec = .{ .shift = 2, .saturate = true, .out_unsigned = true } }, .expect = .{ .value = 0x11003300_55FF7700_993FBBFF_DD00FF00, .saturated = true } },
    .{ .encoding = "VQSHRUN T1", .name = "s32 #1 top", .input = .{ .d = d, .m = m, .size = .half, .half = .top, .spec = .{ .shift = 1, .saturate = true, .out_unsigned = true } }, .expect = .{ .value = 0x00003344_BFFF7788_0000BBCC_0040FF00, .saturated = true } },
};

pub const widening = [_]VWiden{
    .{ .encoding = "VMOVL T1", .name = "s8 bottom", .input = .{ .m = a, .size = .byte, .half = .bottom, .unsigned = false, .left = 0 }, .expect = 0xFFFFFFFF_FFFFFF80_FFFF0001 },
    .{ .encoding = "VMOVL T1", .name = "u16 top", .input = .{ .m = a, .size = .half, .half = .top, .unsigned = true, .left = 0 }, .expect = 0x00008000_00007FFF_000000FF_0000FFFF },
    .{ .encoding = "VMOVL T1", .name = "s16 top", .input = .{ .m = m, .size = .half, .half = .top, .unsigned = false, .left = 0 }, .expect = 0xFFFFFFFF_00000001_FFFFFFFF_00000000 },
    .{ .encoding = "VSHLL T1", .name = "u8 top #8", .input = .{ .m = a, .size = .byte, .half = .top, .unsigned = true, .left = 8 }, .expect = 0x80000000_7F00FF00_00007F00_FF000000 },
    .{ .encoding = "VSHLL T1", .name = "s16 bottom #3", .input = .{ .m = a, .size = .half, .half = .bottom, .unsigned = false, .left = 3 }, .expect = 0xFFFFFFF8_0003FC00_00000008 },
    .{ .encoding = "VSHLL T1", .name = "s8 bottom #7", .input = .{ .m = m, .size = .byte, .half = .bottom, .unsigned = false, .left = 7 }, .expect = 0xFF800000_0080FF80_FF803F80_0000C000 },
};

pub const claimed = [_][]const u8{ "VMOVN T1", "VQMOVN T1", "VQMOVUN T1", "VSHRN T1", "VRSHRN T1", "VQSHRN T1", "VQRSHRN T1", "VQSHRUN T1", "VMOVL T1", "VSHLL T1" };

pub const covered = vector.encodingsOf(NarrowCase, int.Sat, &narrowing) ++
    vector.encodingsOf(WidenCase, u128, &widening);
