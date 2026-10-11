//! Conformance vectors for VCMP and VPT (compare.zig), worked from their
//! pseudocode in the Arm ARM (DDI0553) by /workspace/tools/mve_cmp.py on the
//! lane's box. T1-T3 compare two vectors (I, U, S); T4-T6 compare a vector
//! with Rm in every lane, written here already repeated across the lanes.
const vector = @import("../../conformance/vector.zig");
const qreg = @import("../qreg.zig");
const compare = @import("compare.zig");

pub const CmpCase = struct { a: u128, b: u128, size: qreg.Size, cond: compare.Cond };

const V = vector.Vector(CmpCase, u16);

const a: u128 = 0x80000000_7FFFFFFF_00FF7F80_FFFF0001;
const b: u128 = 0x80000000_00000001_00FF8080_0001FFFF;

pub const vectors = [_]V{
    .{ .encoding = "VCMP T1", .name = "byte eq", .input = .{ .a = a, .b = b, .size = .byte, .cond = .eq }, .expect = 0xF0D0 },
    .{ .encoding = "VCMP T1", .name = "half ne", .input = .{ .a = a, .b = b, .size = .half, .cond = .ne }, .expect = 0x0F3F },
    .{ .encoding = "VCMP T2", .name = "word cs", .input = .{ .a = a, .b = b, .size = .word, .cond = .cs }, .expect = 0xFF0F },
    .{ .encoding = "VCMP T2", .name = "byte hi", .input = .{ .a = a, .b = b, .size = .byte, .cond = .hi }, .expect = 0x0F0C },
    .{ .encoding = "VCMP T3", .name = "half ge", .input = .{ .a = a, .b = b, .size = .half, .cond = .ge }, .expect = 0xFCF3 },
    .{ .encoding = "VCMP T3", .name = "byte lt", .input = .{ .a = a, .b = b, .size = .byte, .cond = .lt }, .expect = 0x070C },
    .{ .encoding = "VCMP T3", .name = "word gt", .input = .{ .a = a, .b = b, .size = .word, .cond = .gt }, .expect = 0x0F00 },
    .{ .encoding = "VCMP T3", .name = "half le", .input = .{ .a = a, .b = b, .size = .half, .cond = .le }, .expect = 0xF3CC },
    .{ .encoding = "VCMP T4", .name = "byte eq Rm=0xFF", .input = .{ .a = a, .b = 0xFFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFF, .size = .byte, .cond = .eq }, .expect = 0x074C },
    .{ .encoding = "VCMP T5", .name = "half cs Rm=0x8000", .input = .{ .a = a, .b = 0x80008000_80008000_80008000_80008000, .size = .half, .cond = .cs }, .expect = 0xC30C },
    .{ .encoding = "VCMP T6", .name = "word gt Rm=0", .input = .{ .a = a, .b = 0, .size = .word, .cond = .gt }, .expect = 0x0FF0 },
    .{ .encoding = "VPT T1", .name = "word ne", .input = .{ .a = a, .b = b, .size = .word, .cond = .ne }, .expect = 0x0FFF },
    .{ .encoding = "VPT T2", .name = "half hi", .input = .{ .a = a, .b = b, .size = .half, .cond = .hi }, .expect = 0x0F0C },
    .{ .encoding = "VPT T3", .name = "byte le", .input = .{ .a = a, .b = b, .size = .byte, .cond = .le }, .expect = 0xF7DC },
    .{ .encoding = "VPT T4", .name = "word eq Rm=0x80000000", .input = .{ .a = a, .b = 0x80000000_80000000_80000000_80000000, .size = .word, .cond = .eq }, .expect = 0xF000 },
    .{ .encoding = "VPT T5", .name = "byte hi Rm=0x7F", .input = .{ .a = a, .b = 0x7F7F7F7F_7F7F7F7F_7F7F7F7F_7F7F7F7F, .size = .byte, .cond = .hi }, .expect = 0x875C },
    .{ .encoding = "VPT T6", .name = "half lt Rm=1", .input = .{ .a = a, .b = 0x00010001_00010001_00010001_00010001, .size = .half, .cond = .lt }, .expect = 0xF30C },
};

pub const claimed = [_][]const u8{
    "VCMP T1", "VCMP T2", "VCMP T3", "VCMP T4", "VCMP T5", "VCMP T6",
    "VPT T1",  "VPT T2",  "VPT T3",  "VPT T4",  "VPT T5",  "VPT T6",
};

pub const covered = vector.encodingsOf(CmpCase, u16, &vectors);
