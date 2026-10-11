//! The 64-bit multiplies (T1): SMULL, UMULL, SMLAL and UMLAL. RdHi:RdLo =
//! Rn * Rm, or that product added to RdHi:RdLo. None of them touch the flags.
//!
//! SP or PC in any register field, or RdHi == RdLo, is UNPREDICTABLE and left
//! unclaimed. UMAAL and the DSP SMLAL<x><y>/SMLALD/SMLSLD forms have other
//! hw2[7:4] values and stay out too.
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;

pub const encodings = struct {
    /// hw1 with Rn ([3:0]) masked out.
    pub const mask: u16 = 0xFFF0;
    pub const smull: u16 = 0xFB80;
    pub const umull: u16 = 0xFBA0;
    pub const smlal: u16 = 0xFBC0;
    pub const umlal: u16 = 0xFBE0;
    /// hw2[7:4] is zero in all four.
    pub const hw2_op2: u16 = 0x00F0;
};

pub const group: op.Group = .{ .name = "long_mul", .decode = decode };

pub const Fields = struct {
    signed: bool,
    accumulate: bool,
    rn: u4,
    rm: u4,
    rd_lo: u4,
    rd_hi: u4,

    pub fn of(instr: Instr) ?Fields {
        if (instr.size != 4 or instr.hw2 & encodings.hw2_op2 != 0) return null;
        const kind = instr.hw1 & encodings.mask;
        switch (kind) {
            encodings.smull, encodings.umull, encodings.smlal, encodings.umlal => {},
            else => return null,
        }
        return .{
            .signed = kind == encodings.smull or kind == encodings.smlal,
            .accumulate = kind == encodings.smlal or kind == encodings.umlal,
            .rn = @intCast(instr.hw1 & 0xF),
            .rm = @intCast(instr.hw2 & 0xF),
            .rd_lo = @intCast(instr.hw2 >> 12),
            .rd_hi = @intCast((instr.hw2 >> 8) & 0xF),
        };
    }
};

fn spOrPc(n: u4) bool {
    return n == 13 or n == 15;
}

fn decode(instr: Instr) ?op.Exec {
    const f = Fields.of(instr) orelse return null;
    if (spOrPc(f.rn) or spOrPc(f.rm) or spOrPc(f.rd_lo) or spOrPc(f.rd_hi)) return null;
    if (f.rd_lo == f.rd_hi) return null;
    return exec;
}

/// The 64-bit product of two registers, signed or unsigned, as raw bits.
pub fn product(a: u32, b: u32, signed: bool) u64 {
    if (!signed) return @as(u64, a) * @as(u64, b);
    const sa: i64 = @as(i32, @bitCast(a));
    const sb: i64 = @as(i32, @bitCast(b));
    return @bitCast(sa * sb);
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = Fields.of(instr).?;
    var result = product(cpu.regs.get(f.rn), cpu.regs.get(f.rm), f.signed);
    if (f.accumulate) {
        const acc = (@as(u64, cpu.regs.get(f.rd_hi)) << 32) | cpu.regs.get(f.rd_lo);
        result +%= acc;
    }
    cpu.regs.set(f.rd_lo, @truncate(result));
    cpu.regs.set(f.rd_hi, @truncate(result >> 32));
}
