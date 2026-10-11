//! MVE VMAXNMV, VMINNMV, VMAXNMAV and VMINNMAV (T1) on F16 and F32 lanes
//! (RA8EMU-23): fold the predicated lanes of Qm into the scalar in Rda.
//! hw1 is 111 sz 1110 1110 11 nma 0 and hw2 is Rda 1111 op 0 M 0 Qm 0, per
//! QEMU's mve.decode and LLVM's assembler: sz=1 is F16, bit 1 clear is the
//! absolute-value (A) form and op=1 is min. These sit at size 11 of the
//! integer VMAXV encoding, which mve_vmaxv.zig leaves alone. M set and Rda
//! of 13 or 15 (UNPREDICTABLE) stay unclaimed. The fold is in
//! src/chip/core/cpu/mve/float/minmax/minmax.zig; an F16 result is zero-extended.
const op = @import("../../../op.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;
const mve = @import("../../../mve/all.zig");
const mve_beats = @import("../beats.zig");
const fpu = @import("../../../fpu/all.zig");
const Size = mve.float.Size;
const Which = fpu.minmax.Which;

pub const group: op.Group = .{ .name = "mve_float_maxnmv", .decode = decode, .oracle = false };

pub const encodings = struct {
    /// hw1 with sz (bit 12) and the non-A bit (1) masked out.
    pub const hw1: u16 = 0xEEEC;
    pub const hw1_mask: u16 = 0xEFFD;
    /// hw2 with Rda (15:12), op (7) and Qm (3:1) masked out; M must be clear.
    pub const hw2: u16 = 0x0F00;
    pub const hw2_mask: u16 = 0x0F71;
};

/// The fields one encoding names.
pub const Fields = struct { rda: u4, qm: u3, size: Size, which: Which, abs: bool };

pub fn fields(instr: Instr) ?Fields {
    if (instr.size != 4 or instr.hw1 & encodings.hw1_mask != encodings.hw1) return null;
    if (instr.hw2 & encodings.hw2_mask != encodings.hw2) return null;
    const rda: u4 = @intCast(instr.hw2 >> 12);
    if (rda == 13 or rda == 15) return null;
    return .{
        .rda = rda,
        .qm = @intCast(instr.hw2 >> 1 & 7),
        .size = if (instr.hw1 >> 12 & 1 == 1) .half else .word,
        .which = if (instr.hw2 >> 7 & 1 == 1) .min else .max,
        .abs = instr.hw1 >> 1 & 1 == 0,
    };
}

fn decode(instr: Instr) ?op.Exec {
    _ = fields(instr) orelse return null;
    return exec;
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = fields(instr).?;
    const m = mve.qreg.read(&cpu.fp.bank, f.qm);
    const mask = mve_beats.mask(cpu);
    const r = mve.float.minmax.reduce(cpu.regs.get(f.rda), m, f.size, f.which, f.abs, mask, &cpu.fp.fpscr);
    cpu.regs.set(f.rda, r);
    mve_beats.finish(cpu);
}
