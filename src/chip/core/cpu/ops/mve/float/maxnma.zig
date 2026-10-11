//! MVE VMAXNMA and VMINNMA on F16 and F32 lanes (T1), predicated by VPR
//! (RA8EMU-23): Qd = maxnum(|Qd|, |Qm|) or minnum. hw1 is 111 sz 1110 0 D
//! 11 1111 and hw2 is Qd op 1110 1 0 M 0 Qm 1, per QEMU's mve.decode and
//! LLVM's assembler: sz=1 is F16 and op=1 is VMINNMA. D and M would name
//! Q8 and above, so they must be zero. hw2 bit 7 clear is VCVTB/VCVTT
//! (mve_float_cvt_half.zig). The lane semantics are in
//! src/chip/core/cpu/mve/float/minmax/minmax.zig.
const op = @import("../../../op.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;
const mve = @import("../../../mve/all.zig");
const mve_beats = @import("../beats.zig");
const fpu = @import("../../../fpu/all.zig");
const Size = mve.float.Size;
const Which = fpu.minmax.Which;

pub const group: op.Group = .{ .name = "mve_float_maxnma", .decode = decode, .oracle = false };

pub const encodings = struct {
    /// hw1 with sz (bit 12) masked out.
    pub const hw1: u16 = 0xEE3F;
    pub const hw1_mask: u16 = 0xEFFF;
    /// hw2 with Qd (15:13), op (12) and Qm (3:1) masked out.
    pub const hw2: u16 = 0x0E81;
    pub const hw2_mask: u16 = 0x0FF1;
};

/// Max or min, or null when the encoding names another op.
pub fn which(instr: Instr) ?Which {
    if (instr.size != 4 or instr.hw1 & encodings.hw1_mask != encodings.hw1) return null;
    if (instr.hw2 & encodings.hw2_mask != encodings.hw2) return null;
    return if (instr.hw2 >> 12 & 1 == 1) .min else .max;
}

fn decode(instr: Instr) ?op.Exec {
    const w = which(instr) orelse return null;
    const half = instr.hw1 >> 12 & 1 == 1;
    return switch (w) {
        inline else => |c| if (half) execFor(c, .half) else execFor(c, .word),
    };
}

fn execFor(comptime w: Which, comptime size: Size) op.Exec {
    return struct {
        fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
            const qd: u3 = @intCast(instr.hw2 >> 13 & 7);
            const qm: u3 = @intCast(instr.hw2 >> 1 & 7);
            const bank = &cpu.fp.bank;
            const old = mve.qreg.read(bank, qd);
            const m = mve.qreg.read(bank, qm);
            const result = mve.float.minmax.lanes(old, old, m, size, w, true, mve_beats.mask(cpu), &cpu.fp.fpscr);
            mve.qreg.write(bank, qd, result);
            mve_beats.finish(cpu);
        }
    }.exec;
}
