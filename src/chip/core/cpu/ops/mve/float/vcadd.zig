//! MVE VCADD (floating point, T1) on F16 and F32 lane pairs, rotation 90
//! or 270, predicated by VPR (RA8EMU-23). hw1 is 1111 110 rot 1 D 0 S Qn 0
//! and hw2 is Qd 0 1000 N 1 M 0 Qm 0, per QEMU's mve.decode and LLVM's
//! assembler: rot=1 is 270 and S=1 is F32 (S=0 F16). D, N and M would name
//! Q8 and above, so they must be zero. Qd == Qm at F32 is UNPREDICTABLE and,
//! as in QEMU, not diagnosed. The lane semantics are in
//! src/chip/core/cpu/mve/float/complex/complex.zig.
const op = @import("../../../op.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;
const mve = @import("../../../mve/all.zig");
const mve_beats = @import("../beats.zig");
const mve_int = @import("../int/int.zig");

pub const group: op.Group = .{ .name = "mve_float_vcadd", .decode = decode, .oracle = false };

pub const encodings = struct {
    /// hw1 with rot (bit 8), S (4) and Qn (3:1) masked out.
    pub const hw1: u16 = 0xFC80;
    pub const hw1_mask: u16 = 0xFEE1;
    /// hw2 with Qd (15:13) and Qm (3:1) masked out.
    pub const hw2: u16 = 0x0840;
    pub const hw2_mask: u16 = 0x1FF1;
};

pub fn claims(instr: Instr) bool {
    return instr.size == 4 and instr.hw1 & encodings.hw1_mask == encodings.hw1 and
        instr.hw2 & encodings.hw2_mask == encodings.hw2;
}

fn decode(instr: Instr) ?op.Exec {
    return if (claims(instr)) exec else null;
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const r = mve_int.regs(instr);
    const bank = &cpu.fp.bank;
    const size: mve.float.Size = if (instr.hw1 >> 4 & 1 == 1) .word else .half;
    const rot270 = instr.hw1 >> 8 & 1 == 1;
    const old = mve.qreg.read(bank, r[0]);
    const n = mve.qreg.read(bank, r[1]);
    const m = mve.qreg.read(bank, r[2]);
    const result = mve.float.complex.cadd(old, n, m, size, rot270, mve_beats.mask(cpu), &cpu.fp.fpscr);
    mve.qreg.write(bank, r[0], result);
    mve_beats.finish(cpu);
}
