//! The halfword multiplies (T1): SMLA<x><y>/SMUL<x><y> on 0xFB10 and
//! SMLAW<y>/SMULW<y> on 0xFB30. Ra = 1111 selects the non-accumulating form.
//!
//! SMLA<x><y>: Rd = Rn.x * Rm.y + Ra, Q set when the sum overflows 32 bits.
//! SMLAW<y>: Rd = (Rn * Rm.y + (Ra << 16))[47:16], Q set on the same kind of
//! overflow. x and y pick the bottom (0) or top (1) signed halfword.
//!
//! Left unclaimed: SP or PC in Rd, Rn or Rm and Ra = SP (UNPREDICTABLE), and
//! nonzero hw2[7:6] (0xFB10) or hw2[7:5] (0xFB30).
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;
const xpsr_bits = @import("../../regs.zig").xpsr_bits;

pub const encodings = struct {
    /// hw1 with Rn ([3:0]) masked out.
    pub const mask: u16 = 0xFFF0;
    pub const smla_xy: u16 = 0xFB10;
    pub const smlaw_y: u16 = 0xFB30;
    pub const xy_zero: u16 = 0x00C0;
    pub const w_zero: u16 = 0x00E0;
    pub const n_bit: u16 = 0x0020;
    pub const m_bit: u16 = 0x0010;
    pub const no_ra: u4 = 15;
};

pub const group: op.Group = .{ .name = "dsp_mul16", .decode = decode };

pub const Fields = struct {
    wide: bool,
    top_n: bool,
    top_m: bool,
    rn: u4,
    ra: u4,
    rd: u4,
    rm: u4,

    pub fn of(instr: Instr) ?Fields {
        if (instr.size != 4) return null;
        const wide = switch (instr.hw1 & encodings.mask) {
            encodings.smla_xy => false,
            encodings.smlaw_y => true,
            else => return null,
        };
        const zero = if (wide) encodings.w_zero else encodings.xy_zero;
        if (instr.hw2 & zero != 0) return null;
        return .{
            .wide = wide,
            .top_n = !wide and instr.hw2 & encodings.n_bit != 0,
            .top_m = instr.hw2 & encodings.m_bit != 0,
            .rn = @intCast(instr.hw1 & 0xF),
            .ra = @intCast(instr.hw2 >> 12),
            .rd = @intCast((instr.hw2 >> 8) & 0xF),
            .rm = @intCast(instr.hw2 & 0xF),
        };
    }
};

pub const Result = struct { value: u32, overflow: bool };

fn spOrPc(n: u4) bool {
    return n == 13 or n == 15;
}

fn decode(instr: Instr) ?op.Exec {
    const f = Fields.of(instr) orelse return null;
    if (spOrPc(f.rd) or spOrPc(f.rn) or spOrPc(f.rm) or f.ra == 13) return null;
    return exec;
}

fn half(v: u32, top: bool) i64 {
    const h: u16 = @truncate(if (top) v >> 16 else v);
    return @as(i16, @bitCast(h));
}

/// Rd for `f` given Rn, Rm and the accumulator (null for the SMUL forms).
pub fn result(f: Fields, rn: u32, rm: u32, ra: ?u32) Result {
    const acc: i64 = if (ra) |a| @as(i32, @bitCast(a)) else 0;
    const m = half(rm, f.top_m);
    const sum: i64 = if (f.wide)
        (@as(i64, @as(i32, @bitCast(rn))) * m + (acc << 16)) >> 16
    else
        half(rn, f.top_n) * m + acc;
    const low: u32 = @truncate(@as(u64, @bitCast(sum)));
    return .{ .value = low, .overflow = sum != @as(i32, @bitCast(low)) };
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = Fields.of(instr).?;
    const ra: ?u32 = if (f.ra == encodings.no_ra) null else cpu.regs.get(f.ra);
    const r = result(f, cpu.regs.get(f.rn), cpu.regs.get(f.rm), ra);
    cpu.regs.set(f.rd, r.value);
    if (r.overflow) cpu.regs.xpsr |= xpsr_bits.q;
}
