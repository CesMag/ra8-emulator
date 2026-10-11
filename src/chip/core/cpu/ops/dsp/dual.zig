//! The dual halfword multiplies (T1): SMLAD/SMUAD on 0xFB20 and SMLSD/SMUSD
//! on 0xFB40. Both multiply the matching signed halfwords of Rn and Rm (Rm's
//! halves swapped when X is set), then add (SMLAD) or subtract (SMLSD) the
//! two products and add Ra. Ra = 1111 selects SMUAD/SMUSD. Q is set when the
//! 64-bit sum does not fit in 32 signed bits (SMUSD never can overflow).
//!
//! Left unclaimed: SP or PC in Rd, Rn or Rm and Ra = SP (UNPREDICTABLE), and
//! nonzero hw2[7:5].
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;
const xpsr_bits = @import("../../regs.zig").xpsr_bits;

pub const encodings = struct {
    /// hw1 with Rn ([3:0]) masked out.
    pub const mask: u16 = 0xFFF0;
    pub const smlad: u16 = 0xFB20;
    pub const smlsd: u16 = 0xFB40;
    pub const hw2_zero: u16 = 0x00E0;
    pub const x_bit: u16 = 0x0010;
    pub const no_ra: u4 = 15;
};

pub const group: op.Group = .{ .name = "dsp_dual", .decode = decode };

pub const Fields = struct {
    subtract: bool,
    swap: bool,
    rn: u4,
    ra: u4,
    rd: u4,
    rm: u4,

    pub fn of(instr: Instr) ?Fields {
        if (instr.size != 4 or instr.hw2 & encodings.hw2_zero != 0) return null;
        const subtract = switch (instr.hw1 & encodings.mask) {
            encodings.smlad => false,
            encodings.smlsd => true,
            else => return null,
        };
        return .{
            .subtract = subtract,
            .swap = instr.hw2 & encodings.x_bit != 0,
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

/// Rd for `f` given Rn, Rm and the accumulator (null for SMUAD/SMUSD).
pub fn result(f: Fields, rn: u32, rm: u32, ra: ?u32) Result {
    const acc: i64 = if (ra) |a| @as(i32, @bitCast(a)) else 0;
    const p1 = half(rn, false) * half(rm, f.swap);
    const p2 = half(rn, true) * half(rm, !f.swap);
    const sum = (if (f.subtract) p1 - p2 else p1 + p2) + acc;
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
