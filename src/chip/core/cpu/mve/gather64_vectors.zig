//! Conformance vectors for the MVE 64-bit gather/scatter beat addresses
//! (gather.beatAddress), worked from the Arm ARM (DDI0553) pseudocode by
//! /workspace/tools/mve_gather64.py on the lane's box.
const vector = @import("../conformance/vector.zig");
const gather = @import("gather/gather.zig");

const V = vector.Vector(gather.Beat, u32);

pub const vectors = [_]V{
    .{ .encoding = "VLDRD.U64 gather", .name = "even beat", .input = .{ .base = 0x20000000, .offset = 0x10, .os = false, .odd = false }, .expect = 0x20000010 },
    .{ .encoding = "VLDRD.U64 gather", .name = "odd beat", .input = .{ .base = 0x20000000, .offset = 0x10, .os = false, .odd = true }, .expect = 0x20000014 },
    .{ .encoding = "VLDRD.U64 gather", .name = "uxtw #3 odd", .input = .{ .base = 0x20000000, .offset = 0x3, .os = true, .odd = true }, .expect = 0x2000001C },
    .{ .encoding = "VLDRD.U64 gather", .name = "wraps", .input = .{ .base = 0xFFFFFFF8, .offset = 0x8, .os = false, .odd = true }, .expect = 0x4 },
    .{ .encoding = "VSTRD.64 scatter", .name = "even beat", .input = .{ .base = 0x20000040, .offset = 0x0, .os = false, .odd = false }, .expect = 0x20000040 },
    .{ .encoding = "VSTRD.64 scatter", .name = "uxtw #3 even", .input = .{ .base = 0x20000000, .offset = 0x2, .os = true, .odd = false }, .expect = 0x20000010 },
    .{ .encoding = "VSTRD.64 scatter", .name = "uxtw #3 large", .input = .{ .base = 0x20000000, .offset = 0x20000000, .os = true, .odd = true }, .expect = 0x20000004 },
};

pub const claimed = [_][]const u8{ "VLDRD.U64 gather", "VSTRD.64 scatter" };

pub const covered = vector.encodingsOf(gather.Beat, u32, &vectors);
