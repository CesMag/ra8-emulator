//! The most-significant-word multiplies (T1): SMMLA/SMMUL on 0xFB50 and
//! SMMLS on 0xFB60. Each forms the 64-bit signed product of Rn and Rm, adds
//! it to (SMMLA) or subtracts it from (SMMLS) Ra shifted up 32 bits, and
//! writes the top word to Rd. Ra = 1111 on 0xFB50 is SMMUL. R (hw2 bit 4)
//! adds 0x8000_0000 before the top word is taken, which rounds instead of
//! truncating. None of them touches the flags.
//!
//! Only bits 63:32 of the sum reach Rd, so wrapping 64-bit arithmetic gives
//! the same top word as the Arm ARM's unbounded integers.
//!
//! Left unclaimed: SP or PC in Rd, Rn or Rm, Ra = SP (UNPREDICTABLE), Ra =
//! 1111 on 0xFB60 (no SMMLS without an accumulator), and nonzero hw2[7:5].
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;

pub const encodings = struct {
    /// hw1 with Rn ([3:0]) masked out.
    pub const mask: u16 = 0xFFF0;
    pub const smmla: u16 = 0xFB50;
    pub const smmls: u16 = 0xFB60;
    pub const hw2_zero: u16 = 0x00E0;
    pub const round_bit: u16 = 0x0010;
    pub const no_ra: u4 = 15;
    pub const round_add: u64 = 0x8000_0000;
};

pub const group: op.Group = .{ .name = "dsp_mulhi", .decode = decode };

pub const Fields = struct {
    subtract: bool,
    round: bool,
    rn: u4,
    ra: u4,
    rd: u4,
    rm: u4,

    pub fn of(instr: Instr) ?Fields {
        if (instr.size != 4 or instr.hw2 & encodings.hw2_zero != 0) return null;
        const subtract = switch (instr.hw1 & encodings.mask) {
            encodings.smmla => false,
            encodings.smmls => true,
            else => return null,
        };
        return .{
            .subtract = subtract,
            .round = instr.hw2 & encodings.round_bit != 0,
            .rn = @intCast(instr.hw1 & 0xF),
            .ra = @intCast(instr.hw2 >> 12),
            .rd = @intCast((instr.hw2 >> 8) & 0xF),
            .rm = @intCast(instr.hw2 & 0xF),
        };
    }
};

fn spOrPc(n: u4) bool {
    return n == 13 or n == 15;
}

fn decode(instr: Instr) ?op.Exec {
    const f = Fields.of(instr) orelse return null;
    if (spOrPc(f.rd) or spOrPc(f.rn) or spOrPc(f.rm) or f.ra == 13) return null;
    if (f.subtract and f.ra == encodings.no_ra) return null;
    return exec;
}

/// Rd for `f` given Rn, Rm and the accumulator (null for SMMUL).
pub fn result(f: Fields, rn: u32, rm: u32, ra: ?u32) u32 {
    const product: i64 = @as(i64, @as(i32, @bitCast(rn))) * @as(i32, @bitCast(rm));
    const p: u64 = @bitCast(product);
    const acc: u64 = if (ra) |a| @as(u64, a) << 32 else 0;
    var sum = if (f.subtract) acc -% p else acc +% p;
    if (f.round) sum +%= encodings.round_add;
    return @truncate(sum >> 32);
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = Fields.of(instr).?;
    const ra: ?u32 = if (f.ra == encodings.no_ra) null else cpu.regs.get(f.ra);
    cpu.regs.set(f.rd, result(f, cpu.regs.get(f.rn), cpu.regs.get(f.rm), ra));
}
