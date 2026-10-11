//! Armv8.1-M single-register saturating and rounding shifts (T1): UQSHL,
//! URSHR, SRSHR and SQSHL by an immediate, UQRSHL and SQRSHR by a register.
//!
//! They sit in the RdaHi = 0b1111 corner of the long-shift space, with the
//! one register Rda in hw1[3:0]:
//!   imm: hw1 = 1110 1010 0101 Rda   hw2 = 0 imm3 1111 imm2 type 1111
//!        type 00 UQSHL, 01 URSHR, 10 SRSHR, 11 SQSHL; imm3:imm2 of 0 is 32
//!   reg: hw1 = 1110 1010 0101 Rda   hw2 = Rm 1111 00 type 1101
//!        type 00 UQRSHL, 10 SQRSHR; the amount is the signed Rm[7:0]
//! UQRSHL shifts left, rounding when the amount is negative; SQRSHR shifts
//! right with rounding, and left with saturation when the amount is
//! negative. A saturating clamp sets APSR.Q; no other flag changes.
//!
//! An Armv8.0-M core reads these as ORRS with PC as Rd; this core claims
//! them first, like the other long shifts (RA8EMU-138). Left unclaimed: Rda of SP or PC, Rm of SP, PC or Rda,
//! hw2 bit 15 set in the immediate form, hw2 bits 7:6 set or type 01 and 11
//! in the register form.
const op = @import("../../../op.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;
const xpsr_bits = @import("../../../regs.zig").xpsr_bits;

pub const Kind = enum { uqshl, urshr, srshr, sqshl, uqrshl, sqrshr };

pub const Fields = struct {
    rda: u4,
    kind: Kind,
    /// The immediate, 1 to 32; zero for the register forms.
    amount: u6 = 0,
    /// The amount register of the register forms.
    rm: ?u4 = null,
};

pub const Result = struct { value: u32, saturated: bool = false };

pub const group: op.Group = .{ .name = "long_shift_sat", .decode = decode, .oracle = true };

pub fn fields(instr: Instr) ?Fields {
    if (instr.size != 4) return null;
    if (instr.hw1 & 0xFFF0 != 0xEA50) return null;
    if (instr.hw2 & 0x0F00 != 0x0F00) return null;
    const rda: u4 = @intCast(instr.hw1 & 0xF);
    if (rda == 13 or rda == 15) return null;
    const kind_bits = (instr.hw2 >> 4) & 0x3;
    if (instr.hw2 & 0x000F == 0xF) {
        if (instr.hw2 & 0x8000 != 0) return null;
        const imm: u6 = @intCast((((instr.hw2 >> 12) & 0x7) << 2) | ((instr.hw2 >> 6) & 0x3));
        const kinds = [_]Kind{ .uqshl, .urshr, .srshr, .sqshl };
        return .{ .rda = rda, .kind = kinds[kind_bits], .amount = if (imm == 0) 32 else imm };
    }
    if (instr.hw2 & 0x00CF != 0x000D) return null;
    const kind: Kind = switch (kind_bits) {
        0b00 => .uqrshl,
        0b10 => .sqrshr,
        else => return null,
    };
    const rm: u4 = @intCast(instr.hw2 >> 12);
    if (rm == 13 or rm == 15 or rm == rda) return null;
    return .{ .rda = rda, .kind = kind, .rm = rm };
}

fn decode(instr: Instr) ?op.Exec {
    _ = fields(instr) orelse return null;
    return exec;
}

/// `src` shifted left by `shift` as an unsigned value, saturating to 32
/// bits; a negative `shift` goes right, rounding when `round` is set.
pub fn unsignedShift(src: u32, shift: i16, round: bool) Result {
    if (shift <= -32 - @as(i16, @intFromBool(round))) return .{ .value = 0 };
    if (shift < 0) {
        if (!round) return .{ .value = src >> @as(u5, @intCast(-shift)) };
        const s = src >> @as(u5, @intCast(-shift - 1));
        return .{ .value = (s >> 1) + (s & 1) };
    }
    if (shift < 32) {
        const n: u5 = @intCast(shift);
        const val = src << n;
        if (val >> n == src) return .{ .value = val };
    } else if (src == 0) return .{ .value = 0 };
    return .{ .value = 0xFFFF_FFFF, .saturated = true };
}

/// The signed counterpart of unsignedShift: saturates to the 32-bit signed
/// range, and a rounded shift of 32 or more is zero.
pub fn signedShift(src: i32, shift: i16, round: bool) Result {
    if (shift <= -32) return .{ .value = if (round) 0 else @bitCast(src >> 31) };
    if (shift < 0) {
        if (!round) return .{ .value = @bitCast(src >> @as(u5, @intCast(-shift))) };
        const s = src >> @as(u5, @intCast(-shift - 1));
        return .{ .value = @bitCast((s >> 1) + (s & 1)) };
    }
    if (shift < 32) {
        const n: u5 = @intCast(shift);
        const val: i32 = @bitCast(@as(u32, @bitCast(src)) << n);
        if (val >> n == src) return .{ .value = @bitCast(val) };
    } else if (src == 0) return .{ .value = 0 };
    return .{ .value = if (src >= 0) 0x7FFF_FFFF else 0x8000_0000, .saturated = true };
}

/// What the instruction leaves in Rda, given Rda and, for the register
/// forms, the value of Rm.
pub fn compute(f: Fields, src: u32, rm_value: u32) Result {
    const amount: i16 = f.amount;
    const by: i16 = @as(i8, @bitCast(@as(u8, @truncate(rm_value))));
    const signed: i32 = @bitCast(src);
    return switch (f.kind) {
        .uqshl => unsignedShift(src, amount, false),
        .urshr => unsignedShift(src, -amount, true),
        .srshr => signedShift(signed, -amount, true),
        .sqshl => signedShift(signed, amount, false),
        .uqrshl => unsignedShift(src, by, true),
        .sqrshr => signedShift(signed, -by, true),
    };
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = fields(instr).?;
    const rm_value = if (f.rm) |m| cpu.regs.get(m) else 0;
    const r = compute(f, cpu.regs.get(f.rda), rm_value);
    cpu.regs.set(f.rda, r.value);
    if (r.saturated) cpu.regs.xpsr |= xpsr_bits.q;
}
