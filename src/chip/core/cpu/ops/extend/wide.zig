//! The 32-bit extends with a rotation (T2) and their accumulating forms (T1):
//! SXTH/SXTAH, UXTH/UXTAH, SXTB/SXTAB and UXTB/UXTAB. Rm is rotated right by
//! 0, 8, 16 or 24, the low halfword or byte is sign- or zero-extended, and the
//! A forms add Rn. Rn = PC is the plain form. No flags change. The extension
//! itself reuses src/chip/core/cpu/ops/extend/extend.zig.
//!
//! Left unclaimed: Rd or Rm of SP or PC and Rn of SP (UNPREDICTABLE), and the
//! dual-halfword SXTB16/UXTB16 rows from the DSP extension.
const std = @import("std");
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;
const extend = @import("extend.zig");

pub const encodings = struct {
    /// hw1 with Rn ([3:0]) masked out.
    pub const mask: u16 = 0xFFF0;
    pub const sxth: u16 = 0xFA00;
    pub const uxth: u16 = 0xFA10;
    pub const sxtb: u16 = 0xFA40;
    pub const uxtb: u16 = 0xFA50;
    /// hw2 with Rd ([11:8]), rotate ([5:4]) and Rm ([3:0]) masked out.
    pub const hw2_mask: u16 = 0xF0C0;
    pub const hw2_fixed: u16 = 0xF080;
};

pub const group: op.Group = .{ .name = "extend_wide", .decode = decode };

pub const Fields = struct {
    kind: extend.Kind,
    rn: u4,
    rd: u4,
    rm: u4,
    /// The right rotation of Rm in bits: 0, 8, 16 or 24.
    rotation: u5,

    pub fn of(instr: Instr) ?Fields {
        if (instr.size != 4 or instr.hw2 & encodings.hw2_mask != encodings.hw2_fixed) return null;
        const kind: extend.Kind = switch (instr.hw1 & encodings.mask) {
            encodings.sxth => .sxth,
            encodings.uxth => .uxth,
            encodings.sxtb => .sxtb,
            encodings.uxtb => .uxtb,
            else => return null,
        };
        const rot: u5 = @intCast((instr.hw2 >> 4) & 0x3);
        return .{
            .kind = kind,
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

/// What Rd gets from Rm, and from Rn when it accumulates (`rn` is null for
/// the plain form).
pub fn result(f: Fields, rm: u32, rn: ?u32) u32 {
    const value = extend.apply(f.kind, std.math.rotr(u32, rm, f.rotation));
    return if (rn) |base| base +% value else value;
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = Fields.of(instr).?;
    const rn: ?u32 = if (f.rn == 15) null else cpu.regs.get(f.rn);
    cpu.regs.set(f.rd, result(f, cpu.regs.get(f.rm), rn));
}
