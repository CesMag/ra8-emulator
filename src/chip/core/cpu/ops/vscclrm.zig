//! VSCCLRM (T1 double, T2 single), Armv8.1-M: zero a run of FP registers
//! and VPR, as the Secure-to-Non-secure veneers do before BXNS. It sits in
//! the VLDMIA space with Rn = PC. hw2[8] picks doubles: d = D:Vd and imm8/2
//! registers; clear, singles: d = Vd:D and imm8 registers. An empty run
//! clears VPR alone.
//!
//! With FPCCR.ASPEN set and CONTROL_S.SFPA clear there is no Secure FP
//! context to scrub, so the instruction is a NOP: no ExecuteFPCheck, no
//! context creation, nothing cleared. Otherwise ExecuteFPCheck runs first.
//! A veneer whose Secure callee used no FP reaches its VSCCLRM this way, and
//! CONTROL has to come out unchanged (RA8EMU-372).
//!
//! VSCCLRM is UNDEFINED in Non-secure state (RA8EMU-549); that check comes
//! before the NOP case. The CPACR NOCP check is RA8EMU-145, the same gap
//! the other FP groups have.
//!
//! Left unclaimed (UNPREDICTABLE): a run past S31 or D15, and an odd imm8
//! in the double form.
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;
const control_bits = @import("../regs.zig").control_bits;
const fp_gate = @import("fp/gate.zig");

pub const encodings = struct {
    /// hw1 with D ([6]) masked out.
    pub const mask: u16 = 0xFFBF;
    pub const vscclrm: u16 = 0xEC9F;
    pub const d_bit: u16 = 1 << 6;
    /// hw2[11:9] = 0b101, the FP register-transfer coprocessor space.
    pub const hw2_mask: u16 = 0x0E00;
    pub const hw2_fixed: u16 = 0x0A00;
    pub const double: u16 = 1 << 8;
};

pub const group: op.Group = .{ .name = "vscclrm", .decode = decode };

/// The single-precision registers a VSCCLRM clears: first and count.
pub const Run = struct { first: u6, count: u6 };

/// The run an encoding clears, or null when it is not VSCCLRM or is
/// UNPREDICTABLE.
pub fn run(instr: Instr) ?Run {
    if (instr.size != 4 or instr.hw1 & encodings.mask != encodings.vscclrm) return null;
    if (instr.hw2 & encodings.hw2_mask != encodings.hw2_fixed) return null;
    const d: u1 = @intFromBool(instr.hw1 & encodings.d_bit != 0);
    const vd: u6 = @intCast(instr.hw2 >> 12);
    const imm8: u8 = @truncate(instr.hw2);
    if (instr.hw2 & encodings.double != 0) {
        if (imm8 & 1 != 0) return null;
        const first: u6 = @as(u6, d) << 4 | vd;
        if (@as(u8, first) + imm8 / 2 > 16) return null;
        return .{ .first = first * 2, .count = @intCast(imm8) };
    }
    const first: u6 = vd << 1 | d;
    if (@as(u8, first) + imm8 > 32) return null;
    return .{ .first = first, .count = @intCast(imm8) };
}

fn decode(instr: Instr) ?op.Exec {
    return if (run(instr) != null) exec else null;
}

/// True when VSCCLRM has no Secure FP context to clear and does nothing.
pub fn idle(cpu: *const Cpu) bool {
    return cpu.fp.context.fpccr.aspen == 1 and cpu.regs.control & control_bits.sfpa == 0;
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    if (cpu.banked.current != .secure) return error.Undefined;
    if (idle(cpu)) return;
    try fp_gate.check(cpu);
    const r = run(instr).?;
    var i: u6 = 0;
    while (i < r.count) : (i += 1) cpu.fp.bank.writeS(@intCast(r.first + i), 0);
    cpu.fp.vpr = .{};
}
