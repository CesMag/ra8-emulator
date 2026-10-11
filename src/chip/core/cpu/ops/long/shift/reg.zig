//! Armv8.1-M scalar long shifts by a register: LSLL and ASRL (T1).
//!
//! The same register pair as the immediate forms in long_shift.zig: RdaLo
//! even, RdaHi odd, the 64-bit value RdaHi:RdaLo shifted and written back.
//! The amount is the signed bottom byte of Rm, -128 to 127. LSLL shifts
//! left for a positive amount and logically right for a negative one; ASRL
//! shifts arithmetically right for a positive amount and left for a
//! negative one. A shift of 64 or more empties the pair, or fills it with
//! the sign bit for an arithmetic right shift. Neither writes the flags.
//!
//!   hw1 = 1110 1010 0101 RdaLo[3:1] 0
//!   hw2 = Rm RdaHi[3:1] 1 00 type 1101, type 00 LSLL, 10 ASRL
//!
//! Like the immediate forms these sit in ORRS-with-SP space that an
//! Armv8.0-M core reads as ORRS; this group claims them (RA8EMU-138).
//! Left unclaimed: RdaHi = 0b1111 (UQRSHL and SQRSHR,
//! RA8EMU-137), hw1 bit 0 set (UQRSHLL and SQRSHRL, RA8EMU-139), type 01
//! and 11, hw2 bits 7:6 set, and the UNPREDICTABLE Rm of SP, PC, RdaLo or
//! RdaHi.
const op = @import("../../../op.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;

pub const Kind = enum { lsll, asrl };

pub const Fields = struct {
    lo: u4,
    hi: u4,
    rm: u4,
    kind: Kind,
};

pub const group: op.Group = .{ .name = "long_shift_reg", .decode = decode, .oracle = true };

pub fn fields(instr: Instr) ?Fields {
    if (instr.size != 4) return null;
    if (instr.hw1 & 0xFFF1 != 0xEA50) return null;
    if (instr.hw2 & 0x01CF != 0x010D) return null;
    const hi: u4 = @intCast((instr.hw2 >> 8) & 0xF);
    if (hi == 0xF or hi == 0xD) return null;
    const kind: Kind = switch ((instr.hw2 >> 4) & 0x3) {
        0b00 => .lsll,
        0b10 => .asrl,
        else => return null,
    };
    const lo: u4 = @intCast(instr.hw1 & 0xE);
    const rm: u4 = @intCast(instr.hw2 >> 12);
    if (rm == 13 or rm == 15 or rm == lo or rm == hi) return null;
    return .{ .lo = lo, .hi = hi, .rm = rm, .kind = kind };
}

fn decode(instr: Instr) ?op.Exec {
    _ = fields(instr) orelse return null;
    return exec;
}

/// `value` shifted the way `kind` says by the signed byte `amount`.
pub fn shift(kind: Kind, value: u64, amount: i8) u64 {
    const n: u8 = @abs(amount);
    const right = switch (kind) {
        .lsll => amount < 0,
        .asrl => amount >= 0,
    };
    if (!right) return if (n >= 64) 0 else value << @intCast(n);
    if (kind == .lsll) return if (n >= 64) 0 else value >> @intCast(n);
    const signed: i64 = @bitCast(value);
    return @bitCast(signed >> @intCast(@min(n, 63)));
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = fields(instr).?;
    const value = (@as(u64, cpu.regs.get(f.hi)) << 32) | cpu.regs.get(f.lo);
    const amount: i8 = @bitCast(@as(u8, @truncate(cpu.regs.get(f.rm))));
    const result = shift(f.kind, value, amount);
    cpu.regs.set(f.lo, @truncate(result));
    cpu.regs.set(f.hi, @truncate(result >> 32));
}
