//! Conformance vectors for the MVE vector bitwise ops in bitwise.zig,
//! worked from the VAND, VBIC (register), VORR (register), VORN and VEOR
//! pseudocode in the Arm ARM (DDI0553). The operands mix all-zero, all-one
//! and alternating bytes, and include Qn == Qm (the VMOV alias of VORR).
const vector = @import("../../conformance/vector.zig");
const bitwise = @import("bitwise.zig");

pub const Case = struct { a: u128, b: u128, op: bitwise.Op };

const V = vector.Vector(Case, u128);

const a: u128 = 0x80000000_7FFFFFFF_00FF7F80_FFFF0001;
const b: u128 = 0x80000000_00000001_01017F81_0001FFFF;
const c: u128 = 0x12345678_9ABCDEF0_0F1E2D3C_4B5A6978;

pub const vectors = [_]V{
    .{ .encoding = "VAND T1", .name = "edges", .input = .{ .a = a, .b = b, .op = .@"and" }, .expect = 0x80000000_00000001_00017F80_00010001 },
    .{ .encoding = "VAND T1", .name = "mixed", .input = .{ .a = c, .b = a, .op = .@"and" }, .expect = 0x00000000_1ABCDEF0_001E2D00_4B5A0000 },
    .{ .encoding = "VAND T1", .name = "Qn == Qm", .input = .{ .a = c, .b = c, .op = .@"and" }, .expect = c },
    .{ .encoding = "VBIC (register) T1", .name = "edges", .input = .{ .a = a, .b = b, .op = .bic }, .expect = 0x00000000_7FFFFFFE_00FE0000_FFFE0000 },
    .{ .encoding = "VBIC (register) T1", .name = "mixed", .input = .{ .a = c, .b = a, .op = .bic }, .expect = 0x12345678_80000000_0F00003C_00006978 },
    .{ .encoding = "VBIC (register) T1", .name = "Qn == Qm clears", .input = .{ .a = c, .b = c, .op = .bic }, .expect = 0 },
    .{ .encoding = "VORR (register) T1", .name = "edges", .input = .{ .a = a, .b = b, .op = .orr }, .expect = 0x80000000_7FFFFFFF_01FF7F81_FFFFFFFF },
    .{ .encoding = "VORR (register) T1", .name = "mixed", .input = .{ .a = c, .b = a, .op = .orr }, .expect = 0x92345678_FFFFFFFF_0FFF7FBC_FFFF6979 },
    .{ .encoding = "VORR (register) T1", .name = "VMOV alias copies", .input = .{ .a = c, .b = c, .op = .orr }, .expect = c },
    .{ .encoding = "VORN T1", .name = "edges", .input = .{ .a = a, .b = b, .op = .orn }, .expect = 0xFFFFFFFF_FFFFFFFF_FEFFFFFE_FFFF0001 },
    .{ .encoding = "VORN T1", .name = "mixed", .input = .{ .a = c, .b = a, .op = .orn }, .expect = 0x7FFFFFFF_9ABCDEF0_FF1EAD7F_4B5AFFFE },
    .{ .encoding = "VORN T1", .name = "Qn == Qm sets", .input = .{ .a = c, .b = c, .op = .orn }, .expect = ~@as(u128, 0) },
    .{ .encoding = "VEOR T1", .name = "edges", .input = .{ .a = a, .b = b, .op = .eor }, .expect = 0x00000000_7FFFFFFE_01FE0001_FFFEFFFE },
    .{ .encoding = "VEOR T1", .name = "mixed", .input = .{ .a = c, .b = a, .op = .eor }, .expect = 0x92345678_E543210F_0FE152BC_B4A56979 },
    .{ .encoding = "VEOR T1", .name = "Qn == Qm clears", .input = .{ .a = c, .b = c, .op = .eor }, .expect = 0 },
};

pub const claimed = [_][]const u8{ "VAND T1", "VBIC (register) T1", "VORR (register) T1", "VORN T1", "VEOR T1" };

pub const covered = vector.encodingsOf(Case, u128, &vectors);
