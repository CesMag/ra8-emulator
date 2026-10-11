//! MVE VMAXNM and VMINNM on F16 and F32 lanes (vector, T1), predicated by
//! VPR (RA8EMU-23). hw1 is 1111 1111 0 D op sz Qn 0 and hw2 is Qd 0 1111 N
//! 1 M 1 Qm 0, per QEMU's mve.decode and LLVM's assembler: op=0 is VMAXNM,
//! op=1 is VMINNM and sz=1 is F16. D, N and M would name Q8 and above, so
//! they must be zero. The lane semantics are in
//! src/chip/core/cpu/mve/float/minmax/minmax.zig.
const op = @import("../../../op.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;
const mve = @import("../../../mve/all.zig");
const mve_beats = @import("../beats.zig");
const mve_int = @import("../int/int.zig");
const fpu = @import("../../../fpu/all.zig");
const Size = mve.float.Size;
const Which = fpu.minmax.Which;

pub const group: op.Group = .{ .name = "mve_float_maxnm", .decode = decode, .oracle = false };

pub const encodings = struct {
    /// hw1 with op (bit 5), sz (4) and Qn (3:1) masked out.
    pub const hw1: u16 = 0xFF00;
    pub const hw1_mask: u16 = 0xFFC1;
    /// hw2 with Qd (15:13) and Qm (3:1) masked out.
    pub const hw2: u16 = 0x0F50;
    pub const hw2_mask: u16 = 0x1FF1;
};

/// Max or min, or null when the encoding names another op.
pub fn which(instr: Instr) ?Which {
    if (instr.size != 4 or instr.hw1 & encodings.hw1_mask != encodings.hw1) return null;
    if (instr.hw2 & encodings.hw2_mask != encodings.hw2) return null;
    return if (instr.hw1 >> 5 & 1 == 1) .min else .max;
}

fn decode(instr: Instr) ?op.Exec {
    const w = which(instr) orelse return null;
    const half = instr.hw1 >> 4 & 1 == 1;
    return switch (w) {
        inline else => |c| if (half) execFor(c, .half) else execFor(c, .word),
    };
}

fn execFor(comptime w: Which, comptime size: Size) op.Exec {
    return struct {
        fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
            const r = mve_int.regs(instr);
            const bank = &cpu.fp.bank;
            const old = mve.qreg.read(bank, r[0]);
            const n = mve.qreg.read(bank, r[1]);
            const m = mve.qreg.read(bank, r[2]);
            const result = mve.float.minmax.lanes(old, n, m, size, w, false, mve_beats.mask(cpu), &cpu.fp.fpscr);
            mve.qreg.write(bank, r[0], result);
            mve_beats.finish(cpu);
        }
    }.exec;
}
