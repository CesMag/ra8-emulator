//! Conformance vectors for VBRSR (bit.reverse.zig), worked from its
//! pseudocode in the Arm ARM (DDI0553) by /workspace/tools/mve_brsr.py on
//! the lane's box.
const vector = @import("../../../conformance/vector.zig");
const qreg = @import("../../qreg.zig");

pub const BrsrCase = struct { a: u128, rm: u32, size: qreg.Size };

const V = vector.Vector(BrsrCase, u128);

const a: u128 = 0x80000000_7FFFFFFF_00FF7F80_FFFF0001;
const c: u128 = 0x12345678_9ABCDEF0_0F1E2D3C_4B5A6978;

pub const vectors = [_]V{
    .{ .encoding = "VBRSR T1", .name = "8 bits of bytes", .input = .{ .a = a, .rm = 0x8, .size = .byte }, .expect = 0x01000000FEFFFFFF00FFFE01FFFF0080 },
    .{ .encoding = "VBRSR T1", .name = "3 bits of bytes", .input = .{ .a = c, .rm = 0x3, .size = .byte }, .expect = 0x02010300020103000703050106020400 },
    .{ .encoding = "VBRSR T1", .name = "Rm above 8 bits ignored", .input = .{ .a = c, .rm = 0x104, .size = .byte }, .expect = 0x04020601050307000F070B030D050901 },
    .{ .encoding = "VBRSR T1", .name = "16 bits of halves", .input = .{ .a = c, .rm = 0x10, .size = .half }, .expect = 0x2C481E6A3D590F7B78F03CB45AD21E96 },
    .{ .encoding = "VBRSR T1", .name = "5 bits of halves", .input = .{ .a = a, .rm = 0x5, .size = .half }, .expect = 0x00000000001F001F001F0000001F0010 },
    .{ .encoding = "VBRSR T1", .name = "zero bits", .input = .{ .a = c, .rm = 0x100, .size = .half }, .expect = 0x00000000000000000000000000000000 },
    .{ .encoding = "VBRSR T1", .name = "32 bits of words", .input = .{ .a = c, .rm = 0x20, .size = .word }, .expect = 0x1E6A2C480F7B3D593CB478F01E965AD2 },
    .{ .encoding = "VBRSR T1", .name = "12 bits of words", .input = .{ .a = a, .rm = 0xC, .size = .word }, .expect = 0x0000000000000FFF0000001F00000800 },
    .{ .encoding = "VBRSR T1", .name = "Rm 200 is all bits", .input = .{ .a = c, .rm = 0xC8, .size = .word }, .expect = 0x1E6A2C480F7B3D593CB478F01E965AD2 },
};

pub const claimed = [_][]const u8{"VBRSR T1"};

pub const covered = vector.encodingsOf(BrsrCase, u128, &vectors);
