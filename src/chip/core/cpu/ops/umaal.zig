//! UMAAL (T1): RdHi:RdLo = Rn * Rm + RdHi + RdLo, all unsigned. The sum always
//! fits in 64 bits. src/chip/core/cpu/ops/long/mul.zig owns the hw2[7:4] = 0000 rows on 0xFBE0
//! (UMLAL); this is the 0110 row.
//!
//! Left unclaimed: SP or PC anywhere, and RdLo == RdHi (UNPREDICTABLE).
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;

pub const encodings = struct {
    /// hw1 with Rn ([3:0]) masked out.
    pub const mask: u16 = 0xFFF0;
    pub const umaal: u16 = 0xFBE0;
    pub const hw2_op_mask: u16 = 0x00F0;
    pub const hw2_op: u16 = 0x0060;
};

pub const group: op.Group = .{ .name = "umaal", .decode = decode };

pub const Fields = struct {
    rn: u4,
    rm: u4,
    rd_lo: u4,
    rd_hi: u4,

    pub fn of(instr: Instr) ?Fields {
        if (instr.size != 4 or instr.hw1 & encodings.mask != encodings.umaal) return null;
        if (instr.hw2 & encodings.hw2_op_mask != encodings.hw2_op) return null;
        return .{
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

/// The 64-bit result for the given operands.
pub fn result(rn: u32, rm: u32, hi: u32, lo: u32) u64 {
    return @as(u64, rn) * rm + hi + lo;
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = Fields.of(instr).?;
    const r = cpu.regs;
    const v = result(r.get(f.rn), r.get(f.rm), r.get(f.rd_hi), r.get(f.rd_lo));
    cpu.regs.set(f.rd_lo, @truncate(v));
    cpu.regs.set(f.rd_hi, @truncate(v >> 32));
}
