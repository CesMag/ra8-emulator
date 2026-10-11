//! Conformance vectors for the MVE contiguous VLDR/VSTR address plan
//! (contiguous.zig), worked from the Arm ARM (DDI0553) pseudocode by
//! /workspace/tools/mve.vldr.py on the lane's box.
const vector = @import("../../conformance/vector.zig");
const contiguous = @import("contiguous.zig");

const V = vector.Vector(contiguous.Form, contiguous.Plan);

pub const vectors = [_]V{
    .{ .encoding = "VLDRB.8", .name = "pre offset add", .input = .{ .base = 0x20000000, .imm7 = 3, .size = .byte, .add = true, .pre = true, .wback = false }, .expect = .{ .start = 0x20000003, .wback = null } },
    .{ .encoding = "VLDRB.8", .name = "post writeback", .input = .{ .base = 0x20000010, .imm7 = 127, .size = .byte, .add = true, .pre = false, .wback = true }, .expect = .{ .start = 0x20000010, .wback = 0x2000008F } },
    .{ .encoding = "VLDRH.16", .name = "pre writeback subtract", .input = .{ .base = 0x20000010, .imm7 = 2, .size = .half, .add = false, .pre = true, .wback = true }, .expect = .{ .start = 0x2000000C, .wback = 0x2000000C } },
    .{ .encoding = "VLDRH.16", .name = "imm 0", .input = .{ .base = 0x20000002, .imm7 = 0, .size = .half, .add = true, .pre = true, .wback = false }, .expect = .{ .start = 0x20000002, .wback = null } },
    .{ .encoding = "VLDRW.32", .name = "post writeback", .input = .{ .base = 0x20000000, .imm7 = 2, .size = .word, .add = true, .pre = false, .wback = true }, .expect = .{ .start = 0x20000000, .wback = 0x20000008 } },
    .{ .encoding = "VLDRW.32", .name = "subtract wraps", .input = .{ .base = 0x4, .imm7 = 3, .size = .word, .add = false, .pre = true, .wback = false }, .expect = .{ .start = 0xFFFFFFF8, .wback = null } },
    .{ .encoding = "VSTRB.8", .name = "pre subtract", .input = .{ .base = 0x20000020, .imm7 = 16, .size = .byte, .add = false, .pre = true, .wback = false }, .expect = .{ .start = 0x20000010, .wback = null } },
    .{ .encoding = "VSTRH.16", .name = "pre offset add", .input = .{ .base = 0x20000000, .imm7 = 1, .size = .half, .add = true, .pre = true, .wback = false }, .expect = .{ .start = 0x20000002, .wback = null } },
    .{ .encoding = "VSTRW.32", .name = "pre writeback subtract", .input = .{ .base = 0x20000040, .imm7 = 2, .size = .word, .add = false, .pre = true, .wback = true }, .expect = .{ .start = 0x20000038, .wback = 0x20000038 } },
    .{ .encoding = "VSTRW.32", .name = "post add wraps", .input = .{ .base = 0xFFFFFFF0, .imm7 = 127, .size = .word, .add = true, .pre = false, .wback = true }, .expect = .{ .start = 0xFFFFFFF0, .wback = 0x1EC } },
};

pub const claimed = [_][]const u8{ "VLDRB.8", "VLDRH.16", "VLDRW.32", "VSTRB.8", "VSTRH.16", "VSTRW.32" };

pub const covered = vector.encodingsOf(contiguous.Form, contiguous.Plan, &vectors);
