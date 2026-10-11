//! Conformance vectors for the MVE widening loads and narrowing stores
//! (contiguous.element), worked from the Arm ARM (DDI0553) pseudocode by
//! /workspace/tools/mve_vldr_wide.py on the lane's box. Their addresses
//! follow contiguous.plan with the memory size, as contiguous_vectors.zig
//! checks for the byte and halfword steps.
const vector = @import("../../conformance/vector.zig");
const contiguous = @import("contiguous.zig");

const V = vector.Vector(contiguous.Element, u32);

pub const vectors = [_]V{
    .{ .encoding = "VLDRB.S16", .name = "negative byte", .input = .{ .value = 0x80, .msize = .byte, .signed = true, .store = false }, .expect = 0xFFFFFF80 },
    .{ .encoding = "VLDRB.S16", .name = "positive byte", .input = .{ .value = 0x7F, .msize = .byte, .signed = true, .store = false }, .expect = 0x7F },
    .{ .encoding = "VLDRB.U16", .name = "high byte", .input = .{ .value = 0xFF, .msize = .byte, .signed = false, .store = false }, .expect = 0xFF },
    .{ .encoding = "VLDRB.S32", .name = "negative byte", .input = .{ .value = 0xF0, .msize = .byte, .signed = true, .store = false }, .expect = 0xFFFFFFF0 },
    .{ .encoding = "VLDRB.U32", .name = "high byte", .input = .{ .value = 0xF0, .msize = .byte, .signed = false, .store = false }, .expect = 0xF0 },
    .{ .encoding = "VLDRH.S32", .name = "negative half", .input = .{ .value = 0x8001, .msize = .half, .signed = true, .store = false }, .expect = 0xFFFF8001 },
    .{ .encoding = "VLDRH.U32", .name = "high half", .input = .{ .value = 0xFFFF, .msize = .half, .signed = false, .store = false }, .expect = 0xFFFF },
    .{ .encoding = "VSTRB.16", .name = "keeps the low byte", .input = .{ .value = 0x1234, .msize = .byte, .signed = false, .store = true }, .expect = 0x34 },
    .{ .encoding = "VSTRB.32", .name = "keeps the low byte", .input = .{ .value = 0xDEADBEEF, .msize = .byte, .signed = false, .store = true }, .expect = 0xEF },
    .{ .encoding = "VSTRH.32", .name = "keeps the low half", .input = .{ .value = 0xDEADBEEF, .msize = .half, .signed = false, .store = true }, .expect = 0xBEEF },
};

pub const claimed = [_][]const u8{ "VLDRB.S16", "VLDRB.U16", "VLDRB.S32", "VLDRB.U32", "VLDRH.S32", "VLDRH.U32", "VSTRB.16", "VSTRB.32", "VSTRH.32" };

pub const covered = vector.encodingsOf(contiguous.Element, u32, &vectors);
