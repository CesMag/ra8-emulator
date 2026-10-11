//! SXTB16/SXTAB16 and UXTB16/UXTAB16 (T1), the DSP dual-byte extends. Rm is
//! rotated right by 0, 8, 16 or 24, then bytes 0 and 2 are sign- or
//! zero-extended into the two halfwords of Rd. The A forms add each halfword
//! of Rn, modulo 2^16 per lane. Rn = PC is the plain form. No flags change.
//!
//! Left unclaimed: Rd or Rm of SP or PC and Rn of SP (UNPREDICTABLE).
const std = @import("std");
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;

pub const encodings = struct {
    /// hw1 with Rn ([3:0]) masked out.
    pub const mask: u16 = 0xFFF0;
    pub const sxtb16: u16 = 0xFA20;
    pub const uxtb16: u16 = 0xFA30;
    /// hw2 with Rd ([11:8]), rotate ([5:4]) and Rm ([3:0]) masked out.
    pub const hw2_mask: u16 = 0xF0C0;
    pub const hw2_fixed: u16 = 0xF080;
};

pub const group: op.Group = .{ .name = "extend_b16", .decode = decode };

pub const Fields = struct {
    signed: bool,
    rn: u4,
    rd: u4,
    rm: u4,
    /// The right rotation of Rm in bits: 0, 8, 16 or 24.
    rotation: u5,

    pub fn of(instr: Instr) ?Fields {
        if (instr.size != 4 or instr.hw2 & encodings.hw2_mask != encodings.hw2_fixed) return null;
        const signed = switch (instr.hw1 & encodings.mask) {
            encodings.sxtb16 => true,
            encodings.uxtb16 => false,
            else => return null,
        };
        const rot: u5 = @intCast((instr.hw2 >> 4) & 0x3);
        return .{
            .signed = signed,
            .rn = @intCast(instr.hw1 & 0xF),
            .rd = @intCast((instr.hw2 >> 8) & 0xF),
            .rm = @intCast(instr.hw2 & 0xF),
            .rotation = rot * 8,
        };
    }
};

fn spOrPc(n: u4) bool {
    return n == 13 or n == 15;
}

fn decode(instr: Instr) ?op.Exec {
    const f = Fields.of(instr) orelse return null;
    if (spOrPc(f.rd) or spOrPc(f.rm) or f.rn == 13) return null;
    return exec;
}

fn byteToHalf(byte: u8, signed: bool) u16 {
    return if (signed) @bitCast(@as(i16, @as(i8, @bitCast(byte)))) else byte;
}

/// What Rd gets from Rm, and from Rn when it accumulates (`rn` is null for
/// the plain form).
pub fn result(f: Fields, rm: u32, rn: ?u32) u32 {
    const rotated = std.math.rotr(u32, rm, f.rotation);
    var lo = byteToHalf(@truncate(rotated), f.signed);
    var hi = byteToHalf(@truncate(rotated >> 16), f.signed);
    if (rn) |base| {
        lo +%= @truncate(base);
        hi +%= @truncate(base >> 16);
    }
    return (@as(u32, hi) << 16) | lo;
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = Fields.of(instr).?;
    const rn: ?u32 = if (f.rn == 15) null else cpu.regs.get(f.rn);
    cpu.regs.set(f.rd, result(f, cpu.regs.get(f.rm), rn));
}
