//! Conformance vectors for the MVE modified immediates in modimm.zig,
//! worked from AdvSIMDExpandImm and the VMOV, VMVN, VORR and VBIC
//! (immediate) pseudocode in the Arm ARM (DDI0553). Every cmode appears,
//! with VMOV.I64, VMOV.F32 (VFPExpandImm) and the ones-fill forms.
const vector = @import("../../conformance/vector.zig");

pub const Case = struct { op: u1, cmode: u4, imm8: u8, qd: u128 = old };

const V = vector.Vector(Case, u128);
const old: u128 = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF;

const mov = "VMOV (vector immediate) T1";
const mvn = "VMVN (immediate) T1";
const orr = "VORR (immediate) T1";
const bic = "VBIC (immediate) T1";

fn v(encoding: []const u8, name: []const u8, op: u1, cmode: u4, imm8: u8, expect: u128) V {
    return .{ .encoding = encoding, .name = name, .input = .{ .op = op, .cmode = cmode, .imm8 = imm8 }, .expect = expect };
}

pub const vectors = [_]V{
    v(mov, "i32 cmode 0000", 0, 0, 0xAB, 0x000000AB_000000AB_000000AB_000000AB),
    v(mov, "i32 cmode 0010 shifts 8", 0, 2, 0xAB, 0x0000AB00_0000AB00_0000AB00_0000AB00),
    v(mov, "i32 cmode 0100 shifts 16", 0, 4, 0xAB, 0x00AB0000_00AB0000_00AB0000_00AB0000),
    v(mov, "i32 cmode 0110 shifts 24", 0, 6, 0xBE, 0xBE000000_BE000000_BE000000_BE000000),
    v(mov, "i16 cmode 1000", 0, 8, 0x80, 0x00800080_00800080_00800080_00800080),
    v(mov, "i16 cmode 1010 shifts 8", 0, 10, 0x80, 0x80008000_80008000_80008000_80008000),
    v(mov, "i32 cmode 1100 fills 0xff", 0, 12, 0x12, 0x000012FF_000012FF_000012FF_000012FF),
    v(mov, "i32 cmode 1101 fills 0xffff", 0, 13, 0x12, 0x0012FFFF_0012FFFF_0012FFFF_0012FFFF),
    v(mov, "i8 cmode 1110", 0, 14, 0x5A, 0x5A5A5A5A_5A5A5A5A_5A5A5A5A_5A5A5A5A),
    v(mov, "i64 cmode 1110 op 1", 1, 14, 0xA5, 0xFF00FF00_00FF00FF_FF00FF00_00FF00FF),
    v(mov, "f32 -3.0", 0, 15, 0x88, 0xC0400000_C0400000_C0400000_C0400000),
    v(mov, "f32 1.0", 0, 15, 0x70, 0x3F800000_3F800000_3F800000_3F800000),
    v(mov, "f32 2.0", 0, 15, 0x00, 0x40000000_40000000_40000000_40000000),
    v(mvn, "i32 cmode 0000", 1, 0, 0xAB, 0xFFFFFF54_FFFFFF54_FFFFFF54_FFFFFF54),
    v(mvn, "i16 cmode 1010", 1, 10, 0x80, 0x7FFF7FFF_7FFF7FFF_7FFF7FFF_7FFF7FFF),
    v(mvn, "i32 cmode 1100", 1, 12, 0x12, 0xFFFFED00_FFFFED00_FFFFED00_FFFFED00),
    v(mvn, "i32 cmode 1101", 1, 13, 0x12, 0xFFED0000_FFED0000_FFED0000_FFED0000),
    v(orr, "i32 cmode 0001", 0, 1, 0x0F, 0xDEADBEEF_CAFEF00F_0123456F_89ABCDEF),
    v(orr, "i32 cmode 0011 shifts 8", 0, 3, 0xF0, 0xDEADFEEF_CAFEF00D_0123F567_89ABFDEF),
    v(orr, "i32 cmode 0111 shifts 24", 0, 7, 0xFF, 0xFFADBEEF_FFFEF00D_FF234567_FFABCDEF),
    v(orr, "i16 cmode 1001", 0, 9, 0x0F, 0xDEAFBEEF_CAFFF00F_012F456F_89AFCDEF),
    v(bic, "i32 cmode 0001", 1, 1, 0xFF, 0xDEADBE00_CAFEF000_01234500_89ABCD00),
    v(bic, "i32 cmode 0011 shifts 8", 1, 3, 0xF0, 0xDEAD0EEF_CAFE000D_01230567_89AB0DEF),
    v(bic, "i16 cmode 1011 shifts 8", 1, 11, 0xF0, 0x0EAD0EEF_0AFE000D_01230567_09AB0DEF),
};

pub const claimed = [_][]const u8{ mov, mvn, orr, bic };
pub const covered = vector.encodingsOf(Case, u128, &vectors);
