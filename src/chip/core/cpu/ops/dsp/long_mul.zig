//! The DSP long multiplies (T1), each accumulating into RdHi:RdLo:
//!   SMLAL<x><y> on 0xFBC0, hw2[7:6] = 10: one signed halfword of Rn (N,
//!     hw2 bit 5) times one of Rm (M, hw2 bit 4).
//!   SMLALD on 0xFBC0 and SMLSLD on 0xFBD0, hw2[7:5] = 110: the bottom
//!     halves multiplied plus (SMLALD) or minus (SMLSLD) the top halves,
//!     with Rm's halves swapped when X (hw2 bit 4) is set.
//! The 64-bit accumulate wraps and none of them touches the flags.
//!
//! Left unclaimed: SP or PC in any register field, RdHi == RdLo
//! (UNPREDICTABLE), and the other hw2[7:4] rows, which belong to
//! ops/long.mul.zig (0000) or are unallocated.
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;

pub const encodings = struct {
    /// hw1 with Rn ([3:0]) masked out.
    pub const mask: u16 = 0xFFF0;
    pub const smlal: u16 = 0xFBC0;
    pub const smlsld: u16 = 0xFBD0;
    pub const halves_mask: u16 = 0x00C0;
    pub const halves: u16 = 0x0080;
    pub const dual_mask: u16 = 0x00E0;
    pub const dual: u16 = 0x00C0;
    pub const n_top: u16 = 0x0020;
    pub const m_top: u16 = 0x0010;
};

pub const Form = union(enum) {
    /// SMLAL<x><y>: which halves of Rn and Rm.
    halves: struct { n_top: bool, m_top: bool },
    /// SMLALD/SMLSLD.
    dual: struct { subtract: bool, swap: bool },
};

pub const group: op.Group = .{ .name = "dsp_long_mul", .decode = decode };

pub const Fields = struct {
    form: Form,
    rn: u4,
    rm: u4,
    rd_lo: u4,
    rd_hi: u4,

    pub fn of(instr: Instr) ?Fields {
        if (instr.size != 4) return null;
        const form = formOf(instr.hw1 & encodings.mask, instr.hw2) orelse return null;
        return .{
            .form = form,
            .rn = @intCast(instr.hw1 & 0xF),
            .rm = @intCast(instr.hw2 & 0xF),
            .rd_lo = @intCast(instr.hw2 >> 12),
            .rd_hi = @intCast((instr.hw2 >> 8) & 0xF),
        };
    }
};

fn formOf(hw1: u16, hw2: u16) ?Form {
    const m_top = hw2 & encodings.m_top != 0;
    if (hw2 & encodings.dual_mask == encodings.dual) return switch (hw1) {
        encodings.smlal => .{ .dual = .{ .subtract = false, .swap = m_top } },
        encodings.smlsld => .{ .dual = .{ .subtract = true, .swap = m_top } },
        else => null,
    };
    if (hw1 == encodings.smlal and hw2 & encodings.halves_mask == encodings.halves)
        return .{ .halves = .{ .n_top = hw2 & encodings.n_top != 0, .m_top = m_top } };
    return null;
}

fn spOrPc(n: u4) bool {
    return n == 13 or n == 15;
}

fn decode(instr: Instr) ?op.Exec {
    const f = Fields.of(instr) orelse return null;
    if (spOrPc(f.rn) or spOrPc(f.rm) or spOrPc(f.rd_lo) or spOrPc(f.rd_hi)) return null;
    if (f.rd_lo == f.rd_hi) return null;
    return exec;
}

fn half(v: u32, top: bool) i64 {
    const h: u16 = @truncate(if (top) v >> 16 else v);
    return @as(i16, @bitCast(h));
}

/// The signed amount `form` adds to the accumulator for Rn and Rm.
pub fn product(form: Form, rn: u32, rm: u32) i64 {
    return switch (form) {
        .halves => |h| half(rn, h.n_top) * half(rm, h.m_top),
        .dual => |d| blk: {
            const p1 = half(rn, false) * half(rm, d.swap);
            const p2 = half(rn, true) * half(rm, !d.swap);
            break :blk if (d.subtract) p1 - p2 else p1 + p2;
        },
    };
}

/// RdHi:RdLo after accumulating `form`'s product into `acc`.
pub fn result(form: Form, rn: u32, rm: u32, acc: u64) u64 {
    return acc +% @as(u64, @bitCast(product(form, rn, rm)));
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = Fields.of(instr).?;
    const acc = (@as(u64, cpu.regs.get(f.rd_hi)) << 32) | cpu.regs.get(f.rd_lo);
    const sum = result(f.form, cpu.regs.get(f.rn), cpu.regs.get(f.rm), acc);
    cpu.regs.set(f.rd_lo, @truncate(sum));
    cpu.regs.set(f.rd_hi, @truncate(sum >> 32));
}
