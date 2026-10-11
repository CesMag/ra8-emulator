//! MVE VFMA and VFMS on F16 and F32 lanes (vector, T1), predicated by VPR
//! (RA8EMU-23). hw1 is 1110 1111 0 D op sz Qn 0 and hw2 is Qd 0 1100 N 1 M
//! 1 Qm 0, per QEMU's mve.decode and LLVM's assembler: op=0 is VFMA
//! (d + n*m), op=1 is VFMS (d - n*m) and sz=1 is F16. D, N and M would name
//! Q8 and above, so they must be zero. The by-scalar VFMA and VFMAS are in
//! mve_float_scalar.zig; the lane semantics are in src/chip/core/cpu/mve/float/float.zig.
const op = @import("../../../op.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;
const mve = @import("../../../mve/all.zig");
const mve_beats = @import("../beats.zig");
const mve_int = @import("../int/int.zig");
const Size = mve.float.Size;
const Fused = mve.float.Fused;

pub const group: op.Group = .{ .name = "mve_float_fma", .decode = decode, .oracle = false };

pub const encodings = struct {
    /// hw1 with op (bit 5), sz (4) and Qn (3:1) masked out.
    pub const hw1: u16 = 0xEF00;
    pub const hw1_mask: u16 = 0xFFC1;
    /// hw2 with Qd (15:13) and Qm (3:1) masked out.
    pub const hw2: u16 = 0x0C50;
    pub const hw2_mask: u16 = 0x1FF1;
};

/// The operation an encoding names, or null when it names another one.
pub fn which(instr: Instr) ?Fused {
    if (instr.size != 4 or instr.hw1 & encodings.hw1_mask != encodings.hw1) return null;
    if (instr.hw2 & encodings.hw2_mask != encodings.hw2) return null;
    return if (instr.hw1 >> 5 & 1 == 1) .fms else .fma;
}

fn decode(instr: Instr) ?op.Exec {
    const w = which(instr) orelse return null;
    const half = instr.hw1 >> 4 & 1 == 1;
    return switch (w) {
        .fma => if (half) execFor(.fma, .half) else execFor(.fma, .word),
        .fms => if (half) execFor(.fms, .half) else execFor(.fms, .word),
        .fmas => null,
    };
}

fn execFor(comptime w: Fused, comptime size: Size) op.Exec {
    return struct {
        fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
            const r = mve_int.regs(instr);
            const bank = &cpu.fp.bank;
            const old = mve.qreg.read(bank, r[0]);
            const n = mve.qreg.read(bank, r[1]);
            const m = mve.qreg.read(bank, r[2]);
            const result = mve.float.fused(old, n, m, size, w, mve_beats.mask(cpu), &cpu.fp.fpscr);
            mve.qreg.write(bank, r[0], result);
            mve_beats.finish(cpu);
        }
    }.exec;
}
