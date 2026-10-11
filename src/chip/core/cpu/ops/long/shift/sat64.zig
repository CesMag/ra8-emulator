//! Armv8.1-M 64-bit saturating and rounding long shifts (T1): UQSHLL,
//! URSHRL, SRSHRL and SQSHLL by an immediate, UQRSHLL and SQRSHRL by a
//! register, the register forms saturating at 64 or 48 bits.
//!
//! The RdaHi:RdaLo pair is the same even/odd pair as LSLL (long_shift.zig);
//! what sets these apart is hw1 bit 0:
//!   imm: hw1 = 1110 1010 0101 RdaLo[3:1] 1
//!        hw2 = 0 imm3 RdaHi[3:1] 1 imm2 type 1111
//!        type 00 UQSHLL, 01 URSHRL, 10 SRSHRL, 11 SQSHLL; imm3:imm2 0 is 32
//!   reg: hw1 = 1110 1010 0101 RdaLo[3:1] 1
//!        hw2 = Rm RdaHi[3:1] 1 sat 0 type 1101
//!        type 00 UQRSHLL, 10 SQRSHRL; sat set saturates at 48 bits
//! The register amount is the signed Rm[7:0]. Rounding is half up, a
//! saturating clamp sets APSR.Q, and a 48-bit result is zero- or
//! sign-extended into the pair. RdaHi = 0b1111 is the single-register
//! space (long_shift_sat.zig).
//!
//! Claimed ahead of ORRS like the other long shifts (RA8EMU-138).
//! Left unclaimed: RdaHi of SP, hw2 bit 15 in the immediate form, hw2 bit 6
//! or type 01 and 11 in the register form, and Rm of SP, PC, RdaLo or
//! RdaHi.
const op = @import("../../../op.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;
const xpsr_bits = @import("../../../regs.zig").xpsr_bits;

pub const Kind = enum { uqshll, urshrl, srshrl, sqshll, uqrshll, sqrshrl };

pub const Fields = struct {
    lo: u4,
    hi: u4,
    kind: Kind,
    /// The immediate, 1 to 32; zero for the register forms.
    amount: u6 = 0,
    /// The amount register of the register forms.
    rm: ?u4 = null,
    /// Where the register forms saturate: 64 or 48.
    bits: u7 = 64,
};

pub const Result = struct { value: u64, saturated: bool = false };

pub const group: op.Group = .{ .name = "long_shift_sat64", .decode = decode, .oracle = true };

pub fn fields(instr: Instr) ?Fields {
    if (instr.size != 4) return null;
    if (instr.hw1 & 0xFFF1 != 0xEA51) return null;
    if (instr.hw2 & 0x0100 == 0) return null;
    const lo: u4 = @intCast(instr.hw1 & 0xE);
    const hi: u4 = @intCast((instr.hw2 >> 8) & 0xF);
    if (hi == 15 or hi == 13) return null;
    const kind_bits = (instr.hw2 >> 4) & 0x3;
    if (instr.hw2 & 0x000F == 0xF) {
        if (instr.hw2 & 0x8000 != 0) return null;
        const imm: u6 = @intCast((((instr.hw2 >> 12) & 0x7) << 2) | ((instr.hw2 >> 6) & 0x3));
        const kinds = [_]Kind{ .uqshll, .urshrl, .srshrl, .sqshll };
        return .{ .lo = lo, .hi = hi, .kind = kinds[kind_bits], .amount = if (imm == 0) 32 else imm };
    }
    if (instr.hw2 & 0x004F != 0x000D) return null;
    const kind: Kind = switch (kind_bits) {
        0b00 => .uqrshll,
        0b10 => .sqrshrl,
        else => return null,
    };
    const rm: u4 = @intCast(instr.hw2 >> 12);
    if (rm == 13 or rm == 15 or rm == lo or rm == hi) return null;
    const bits: u7 = if (instr.hw2 & 0x0080 != 0) 48 else 64;
    return .{ .lo = lo, .hi = hi, .kind = kind, .rm = rm, .bits = bits };
}

fn decode(instr: Instr) ?op.Exec {
    _ = fields(instr) orelse return null;
    return exec;
}

fn lowMask(bits: u7) u64 {
    return if (bits >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(bits)) - 1;
}

fn signExtend(value: i64, bits: u7) i64 {
    if (bits >= 64) return value;
    const pad: u6 = @intCast(64 - @as(u8, bits));
    const shifted: i64 = @bitCast(@as(u64, @bitCast(value)) << pad);
    return shifted >> pad;
}

/// `src` shifted left by `shift` as an unsigned value, saturating to
/// `bits`; a negative `shift` goes right, rounding when `round` is set.
pub fn unsignedShift(src: u64, shift: i16, round: bool, bits: u7) Result {
    const width: i16 = bits;
    const mask = lowMask(bits);
    if (shift <= -width - @as(i16, @intFromBool(round))) return .{ .value = 0 };
    if (shift < 0) {
        const val = if (round) blk: {
            const s = src >> @as(u6, @intCast(-shift - 1));
            break :blk (s >> 1) + (s & 1);
        } else src >> @as(u6, @intCast(-shift));
        if (val & mask == val) return .{ .value = val };
    } else if (shift < width) {
        const n: u6 = @intCast(shift);
        const ext = (src << n) & mask;
        if (ext >> n == src) return .{ .value = ext };
    } else if (src == 0) return .{ .value = 0 };
    return .{ .value = mask, .saturated = true };
}

/// The signed counterpart of unsignedShift: saturates to the signed range
/// of `bits` and returns the result sign-extended to 64 bits.
pub fn signedShift(src: i64, shift: i16, round: bool, bits: u7) Result {
    const width: i16 = bits;
    if (shift <= -width) return .{ .value = if (round) 0 else @bitCast(src >> 63) };
    if (shift < 0) {
        const val = if (round) blk: {
            const s = src >> @as(u6, @intCast(-shift - 1));
            break :blk (s >> 1) + (s & 1);
        } else src >> @as(u6, @intCast(-shift));
        if (signExtend(val, bits) == val) return .{ .value = @bitCast(val) };
    } else if (shift < width) {
        const n: u6 = @intCast(shift);
        const ext = signExtend(@bitCast(@as(u64, @bitCast(src)) << n), bits);
        if (ext >> n == src) return .{ .value = @bitCast(ext) };
    } else if (src == 0) return .{ .value = 0 };
    const top = lowMask(bits - 1);
    return .{ .value = if (src >= 0) top else ~top, .saturated = true };
}

/// What the instruction leaves in the pair, given the pair and, for the
/// register forms, the value of Rm.
pub fn compute(f: Fields, src: u64, rm_value: u32) Result {
    const amount: i16 = f.amount;
    const by: i16 = @as(i8, @bitCast(@as(u8, @truncate(rm_value))));
    const signed: i64 = @bitCast(src);
    return switch (f.kind) {
        .uqshll => unsignedShift(src, amount, false, 64),
        .urshrl => unsignedShift(src, -amount, true, 64),
        .srshrl => signedShift(signed, -amount, true, 64),
        .sqshll => signedShift(signed, amount, false, 64),
        .uqrshll => unsignedShift(src, by, true, f.bits),
        .sqrshrl => signedShift(signed, -by, true, f.bits),
    };
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = fields(instr).?;
    const src = (@as(u64, cpu.regs.get(f.hi)) << 32) | cpu.regs.get(f.lo);
    const rm_value = if (f.rm) |m| cpu.regs.get(m) else 0;
    const r = compute(f, src, rm_value);
    cpu.regs.set(f.lo, @truncate(r.value));
    cpu.regs.set(f.hi, @truncate(r.value >> 32));
    if (r.saturated) cpu.regs.xpsr |= xpsr_bits.q;
}
