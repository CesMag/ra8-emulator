//! MVE VCMUL (T1) on F16 and F32 lane pairs, rotation 0, 90, 180 or 270,
//! predicated by VPR (RA8EMU-23). hw1 is 111 sz 1110 0 D 11 Qn 0 and hw2 is
//! Qd rot_hi 1110 N 0 M 0 Qm rot_lo, per QEMU's mve.decode and LLVM's
//! assembler: sz=1 is F32 (sz=0 F16) and rot = rot_hi:rot_lo quarter turns.
//! These are size 11 of the VQDMLADH/VQRDMLADH family, which claims sizes
//! 0 to 2 only. D, N and M would name Q8 and above, so they must be zero.
//! The lane semantics are in src/chip/core/cpu/mve/float/complex/complex.zig.
const op = @import("../../../op.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;
const mve = @import("../../../mve/all.zig");
const mve_beats = @import("../beats.zig");
const mve_int = @import("../int/int.zig");

pub const group: op.Group = .{ .name = "mve_float_vcmul", .decode = decode, .oracle = false };

pub const encodings = struct {
    /// hw1 with sz (bit 12) and Qn (3:1) masked out.
    pub const hw1: u16 = 0xEE30;
    pub const hw1_mask: u16 = 0xEFF1;
    /// hw2 with Qd (15:13), rot_hi (12), Qm (3:1) and rot_lo (0) masked out.
    pub const hw2: u16 = 0x0E00;
    pub const hw2_mask: u16 = 0x0FF0;
};

pub fn claims(instr: Instr) bool {
    return instr.size == 4 and instr.hw1 & encodings.hw1_mask == encodings.hw1 and
        instr.hw2 & encodings.hw2_mask == encodings.hw2;
}

/// The rotation in quarter turns.
pub fn rotation(instr: Instr) u2 {
    return @intCast((instr.hw2 >> 11 & 2) | (instr.hw2 & 1));
}

fn decode(instr: Instr) ?op.Exec {
    return if (claims(instr)) exec else null;
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const r = mve_int.regs(instr);
    const bank = &cpu.fp.bank;
    const size: mve.float.Size = if (instr.hw1 >> 12 & 1 == 1) .word else .half;
    const old = mve.qreg.read(bank, r[0]);
    const n = mve.qreg.read(bank, r[1]);
    const m = mve.qreg.read(bank, r[2]);
    const result = mve.float.complex.cmla(old, n, m, size, rotation(instr), false, mve_beats.mask(cpu), &cpu.fp.fpscr);
    mve.qreg.write(bank, r[0], result);
    mve_beats.finish(cpu);
}
