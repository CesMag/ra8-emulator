//! Conformance vectors for VMAXV, VMINV, VMAXAV and VMINAV
//! (reduce_minmax.zig), worked from their pseudocode in the Arm ARM
//! (DDI0553) by /workspace/tools/mve_maxv.py on the lane's box. `mask` is
//! the VPT element mask, one bit per byte.
const vector = @import("../../../conformance/vector.zig");
const qreg = @import("../../qreg.zig");
const reduce_minmax = @import("minmax.zig");

pub const MaxCase = struct { acc: u32, a: u128, size: qreg.Size, mask: u16, form: reduce_minmax.Form };

const V = vector.Vector(MaxCase, u32);

const a: u128 = 0x80000000_7FFFFFFF_00FF7F80_FFFF0001;

pub const vectors = [_]V{
    .{ .encoding = "VMAXV T1", .name = "s8", .input = .{ .acc = 0x80, .a = a, .size = .byte, .mask = 0xFFFF, .form = .{ .kind = .max } }, .expect = 0x7F },
    .{ .encoding = "VMAXV T1", .name = "s16 Rda wins", .input = .{ .acc = 0x7FFF, .a = a, .size = .half, .mask = 0xFFFF, .form = .{ .kind = .max } }, .expect = 0x7FFF },
    .{ .encoding = "VMAXV T1", .name = "u8", .input = .{ .acc = 0x0, .a = a, .size = .byte, .mask = 0xFFFF, .form = .{ .kind = .max, .unsigned = true } }, .expect = 0xFF },
    .{ .encoding = "VMAXV T1", .name = "u32 masked", .input = .{ .acc = 0x0, .a = a, .size = .word, .mask = 0x0FFF, .form = .{ .kind = .max, .unsigned = true } }, .expect = 0xFFFF0001 },
    .{ .encoding = "VMINV T1", .name = "s32", .input = .{ .acc = 0x7FFFFFFF, .a = a, .size = .word, .mask = 0xFFFF, .form = .{ .kind = .min } }, .expect = 0x80000000 },
    .{ .encoding = "VMINV T1", .name = "u16 Rda high bits dropped", .input = .{ .acc = 0xFFFF0005, .a = a, .size = .half, .mask = 0xFFFF, .form = .{ .kind = .min, .unsigned = true } }, .expect = 0x0 },
    .{ .encoding = "VMINV T1", .name = "s8 masked", .input = .{ .acc = 0x7F, .a = a, .size = .byte, .mask = 0x00F0, .form = .{ .kind = .min } }, .expect = 0xFFFFFF80 },
    .{ .encoding = "VMAXAV T1", .name = "s8 abs of -128", .input = .{ .acc = 0x0, .a = a, .size = .byte, .mask = 0xFFFF, .form = .{ .kind = .max, .abs = true } }, .expect = 0x80 },
    .{ .encoding = "VMAXAV T1", .name = "s32", .input = .{ .acc = 0x0, .a = a, .size = .word, .mask = 0xFFFF, .form = .{ .kind = .max, .abs = true } }, .expect = 0x80000000 },
    .{ .encoding = "VMINAV T1", .name = "s16", .input = .{ .acc = 0xFFFF, .a = a, .size = .half, .mask = 0xFFFF, .form = .{ .kind = .min, .abs = true } }, .expect = 0x0 },
    .{ .encoding = "VMINAV T1", .name = "s8 none active", .input = .{ .acc = 0x1234, .a = a, .size = .byte, .mask = 0x0000, .form = .{ .kind = .min, .abs = true } }, .expect = 0x34 },
};

pub const claimed = [_][]const u8{ "VMAXV T1", "VMINV T1", "VMAXAV T1", "VMINAV T1" };

pub const covered = vector.encodingsOf(MaxCase, u32, &vectors);
