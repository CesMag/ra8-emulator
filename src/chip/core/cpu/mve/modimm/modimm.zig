//! MVE one-register modified immediates from the Arm ARM (DDI0553)
//! pseudocode (RA8EMU-633): VMOV, VMVN, VORR and VBIC (immediate).
//! AdvSIMDExpandImm turns op, cmode and imm8 into a 64-bit pattern that
//! fills both halves of the vector. cmode 0xx1 and 10x1 are VORR (op 0)
//! or VBIC (op 1); every other cmode is VMOV (op 0) or VMVN (op 1), except
//! that cmode 1110 with op 1 is VMOV.I64 and cmode 1111 with op 1 is
//! UNDEFINED. Predication and beats are applied by whoever writes Qd.
const fpu_imm = @import("../../fpu/imm.zig");
const single = @import("../../fpu/format.zig").single;
pub const vectors = @import("vectors.zig");

pub const Op = enum { mov, mvn, orr, bic };

/// Which instruction op and cmode name, or null when UNDEFINED.
pub fn kind(op: u1, cmode: u4) ?Op {
    const logical = cmode & 1 == 1 and cmode < 12;
    if (logical) return if (op == 0) .orr else .bic;
    if (op == 0 or cmode == 14) return .mov;
    return if (cmode == 15) null else .mvn;
}

/// AdvSIMDExpandImm as a full 128-bit vector, or null when UNDEFINED.
pub fn expand(op: u1, cmode: u4, imm8: u8) ?u128 {
    const i: u64 = imm8;
    const half: u64 = switch (cmode >> 1) {
        0 => rep32(i),
        1 => rep32(i << 8),
        2 => rep32(i << 16),
        3 => rep32(i << 24),
        4 => rep16(i),
        5 => rep16(i << 8),
        6 => rep32(if (cmode & 1 == 0) i << 8 | 0xFF else i << 16 | 0xFFFF),
        else => if (cmode & 1 == 0)
            (if (op == 0) i * 0x0101_0101_0101_0101 else bytes(imm8))
        else if (op == 0)
            rep32(fpu_imm.expandImm(single, imm8))
        else
            return null,
    };
    return @as(u128, half) << 64 | half;
}

/// Qd after the instruction, from its old value, or null when UNDEFINED.
pub fn run(op: u1, cmode: u4, imm8: u8, old: u128) ?u128 {
    const k = kind(op, cmode) orelse return null;
    const imm = expand(op, cmode, imm8) orelse return null;
    return switch (k) {
        .mov => imm,
        .mvn => ~imm,
        .orr => old | imm,
        .bic => old & ~imm,
    };
}

fn rep32(x: u64) u64 {
    return x << 32 | x;
}

fn rep16(x: u64) u64 {
    return rep32(x << 16 | x);
}

/// VMOV.I64: bit n of imm8 sets byte n to 0xFF.
fn bytes(imm8: u8) u64 {
    var out: u64 = 0;
    for (0..8) |n| {
        if (imm8 >> @intCast(n) & 1 == 1) out |= @as(u64, 0xFF) << @intCast(8 * n);
    }
    return out;
}
