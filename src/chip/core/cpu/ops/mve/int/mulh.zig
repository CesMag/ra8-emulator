//! MVE VMULH, VRMULH, VQDMULH and VQRDMULH (vector, T1), predicated by
//! VPR (RA8EMU-25). Encodings per LLVM's assembler:
//! VMULH/VRMULH: hw1 111U 1110 0 D size Qn 1, hw2 Qd R 1 1 1 0 N 0 M 0 Qm 1.
//! VQDMULH/VQRDMULH: hw1 111R 1111 0 D size Qn 0, hw2 Qd 0 1 0 1 1 N 1 M 0
//! Qm 0, where hw1's U position selects rounding. The doubling forms raise
//! FPSCR.QC only from lanes the VPT block leaves active. Lane semantics are
//! in src/chip/core/cpu/mve/int/mul/mul.zig.
const op = @import("../../../op.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;
const mve = @import("../../../mve/all.zig");
const mve_beats = @import("../beats.zig");
const mve_int = @import("int.zig");
const pair = @import("pair.zig");
const Size = mve.qreg.Size;
const High = mve.int.mul.High;

pub const group: op.Group = .{ .name = "mve_int_mulh", .decode = decode, .oracle = false };

pub const encodings = struct {
    /// hw1 of VMULH and VRMULH under mve_int.encodings.hw1_mask.
    pub const mulh_hw1: u16 = 0xEE01;
    /// hw2 under mve_int.encodings.hw2_mask.
    pub const vmulh: u16 = 0x0E01;
    pub const vrmulh: u16 = 0x1E01;
    /// VQDMULH and VQRDMULH share mve_int.encodings.hw1.
    pub const vqdmulh: u16 = 0x0B40;
};

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4) return null;
    const size = instr.hw1 >> 4 & 3;
    if (size == 3) return null;
    const u = instr.hw1 >> 12 & 1 == 1;
    const masked = instr.hw1 & mve_int.encodings.hw1_mask;
    const tail = instr.hw2 & mve_int.encodings.hw2_mask;
    const key: u2 = if (masked == encodings.mulh_hw1 and tail == encodings.vmulh)
        (if (u) 1 else 0)
    else if (masked == encodings.mulh_hw1 and tail == encodings.vrmulh)
        (if (u) 3 else 2)
    else if (masked == mve_int.encodings.hw1 and tail == encodings.vqdmulh)
        return if (u) pick(size, .{ .round = true, .double = true }) else pick(size, .{ .double = true })
    else
        return null;
    return switch (key) {
        0 => pick(size, .{}),
        1 => pick(size, .{ .unsigned = true }),
        2 => pick(size, .{ .round = true }),
        3 => pick(size, .{ .unsigned = true, .round = true }),
    };
}

fn pick(size: u16, comptime h: High) op.Exec {
    return switch (size) {
        0 => execFor(.byte, h),
        1 => execFor(.half, h),
        else => execFor(.word, h),
    };
}

fn execFor(comptime size: Size, comptime h: High) op.Exec {
    return struct {
        fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
            const r = mve_int.regs(instr);
            const a = mve.qreg.read(&cpu.fp.bank, r[1]);
            const b = mve.qreg.read(&cpu.fp.bank, r[2]);
            const result = mve.int.mul.multiplyHigh(a, b, size, h);
            if (h.double) {
                const live = pair.activeLanes(mve_beats.mask(cpu), size);
                if (mve.int.mul.multiplyHigh(a & live, b, size, h).saturated) cpu.fp.fpscr.qc = 1;
            }
            mve_int.writePredicated(cpu, r[0], result.value);
        }
    }.exec;
}
