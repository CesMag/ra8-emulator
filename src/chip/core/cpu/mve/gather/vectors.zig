//! Conformance vectors for the MVE gather/scatter addresses (gather.zig),
//! worked from the Arm ARM (DDI0553) pseudocode by
//! /workspace/tools/mve_gather.py on the lane's box. Element widening and
//! narrowing is covered by contiguous_wide_vectors.zig.
const vector = @import("../../conformance/vector.zig");
const gather = @import("gather.zig");

const V = vector.Vector(gather.Address, u32);

pub const vectors = [_]V{
    .{ .encoding = "VLDRB.U8 gather", .name = "byte offset", .input = .{ .base = 0x20000000, .offset = 0x7F, .msize = .byte, .os = false }, .expect = 0x2000007F },
    .{ .encoding = "VLDRB.S16 gather", .name = "half offset", .input = .{ .base = 0x20000000, .offset = 0xFFFF, .msize = .byte, .os = false }, .expect = 0x2000FFFF },
    .{ .encoding = "VLDRB.U16 gather", .name = "zero offset", .input = .{ .base = 0x20000010, .offset = 0x0, .msize = .byte, .os = false }, .expect = 0x20000010 },
    .{ .encoding = "VLDRB.S32 gather", .name = "wraps", .input = .{ .base = 0xFFFFFFF0, .offset = 0x20, .msize = .byte, .os = false }, .expect = 0x10 },
    .{ .encoding = "VLDRB.U32 gather", .name = "word offset", .input = .{ .base = 0x20000000, .offset = 0x100, .msize = .byte, .os = false }, .expect = 0x20000100 },
    .{ .encoding = "VLDRH.U16 gather", .name = "uxtw #1", .input = .{ .base = 0x20000000, .offset = 0x3, .msize = .half, .os = true }, .expect = 0x20000006 },
    .{ .encoding = "VLDRH.U16 gather", .name = "unscaled odd", .input = .{ .base = 0x20000000, .offset = 0x3, .msize = .half, .os = false }, .expect = 0x20000003 },
    .{ .encoding = "VLDRH.S32 gather", .name = "unscaled", .input = .{ .base = 0x20000004, .offset = 0x6, .msize = .half, .os = false }, .expect = 0x2000000A },
    .{ .encoding = "VLDRH.S32 gather", .name = "uxtw #1", .input = .{ .base = 0x20000004, .offset = 0x6, .msize = .half, .os = true }, .expect = 0x20000010 },
    .{ .encoding = "VLDRH.U32 gather", .name = "uxtw #1 large", .input = .{ .base = 0x20000000, .offset = 0x80000000, .msize = .half, .os = true }, .expect = 0x20000000 },
    .{ .encoding = "VLDRW.U32 gather", .name = "uxtw #2", .input = .{ .base = 0x20000000, .offset = 0x5, .msize = .word, .os = true }, .expect = 0x20000014 },
    .{ .encoding = "VSTRB.8 scatter", .name = "byte offset", .input = .{ .base = 0x20000040, .offset = 0x10, .msize = .byte, .os = false }, .expect = 0x20000050 },
    .{ .encoding = "VSTRB.16 scatter", .name = "half offset", .input = .{ .base = 0x20000000, .offset = 0x1234, .msize = .byte, .os = false }, .expect = 0x20001234 },
    .{ .encoding = "VSTRB.32 scatter", .name = "word offset", .input = .{ .base = 0x20000000, .offset = 0x40, .msize = .byte, .os = false }, .expect = 0x20000040 },
    .{ .encoding = "VSTRH.16 scatter", .name = "uxtw #1", .input = .{ .base = 0x20000000, .offset = 0x8, .msize = .half, .os = true }, .expect = 0x20000010 },
    .{ .encoding = "VSTRH.32 scatter", .name = "unscaled", .input = .{ .base = 0x20000000, .offset = 0x2, .msize = .half, .os = false }, .expect = 0x20000002 },
    .{ .encoding = "VSTRW.32 scatter", .name = "uxtw #2 wraps", .input = .{ .base = 0x10, .offset = 0xFFFFFFFC, .msize = .word, .os = true }, .expect = 0x0 },
    .{ .encoding = "VSTRW.32 scatter", .name = "unscaled", .input = .{ .base = 0x20000000, .offset = 0x4, .msize = .word, .os = false }, .expect = 0x20000004 },
};

pub const claimed = [_][]const u8{
    "VLDRB.U8 gather",  "VLDRB.S16 gather", "VLDRB.U16 gather", "VLDRB.S32 gather", "VLDRB.U32 gather",
    "VLDRH.U16 gather", "VLDRH.S32 gather", "VLDRH.U32 gather", "VLDRW.U32 gather", "VSTRB.8 scatter",
    "VSTRB.16 scatter", "VSTRB.32 scatter", "VSTRH.16 scatter", "VSTRH.32 scatter", "VSTRW.32 scatter",
};

pub const covered = vector.encodingsOf(gather.Address, u32, &vectors);
