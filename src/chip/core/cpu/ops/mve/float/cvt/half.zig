//! MVE VCVTB and VCVTT between F16 and F32 lanes (T1), predicated by VPR
//! (RA8EMU-23). hw1 is 111 op 1110 0 D 11 1111 and hw2 is Qd T 1110 0 0 M
//! 0 Qm 1, per QEMU's mve.decode and LLVM's assembler: op=0 narrows F32 to
//! F16 (vcvtb/vcvtt.f16.f32), op=1 widens F16 to F32, and T picks the top
//! half of each word. D and M would name Q8 and above, so they must be
//! zero. hw2 bit 7 set is VMAXNMA/VMINNMA and is left to its own group.
//! The lane semantics are in src/chip/core/cpu/mve/float/cvt/cvt.zig.
const op = @import("../../../../op.zig");
const Cpu = @import("../../../../cpu.zig").Cpu;
const Instr = @import("../../../../instr.zig").Instr;
const mve = @import("../../../../mve/all.zig");
const mve_beats = @import("../../beats.zig");

pub const group: op.Group = .{ .name = "mve_float_cvt_half", .decode = decode, .oracle = false };

pub const encodings = struct {
    /// hw1 with op (bit 12) masked out.
    pub const hw1: u16 = 0xEE3F;
    pub const hw1_mask: u16 = 0xEFFF;
    /// hw2 with Qd (15:13), T (12) and Qm (3:1) masked out.
    pub const hw2: u16 = 0x0E01;
    pub const hw2_mask: u16 = 0x0FF1;
};

/// The fields one encoding names.
pub const Fields = struct { qd: u3, qm: u3, widen: bool, top: bool };

pub fn fields(instr: Instr) ?Fields {
    if (instr.size != 4 or instr.hw1 & encodings.hw1_mask != encodings.hw1) return null;
    if (instr.hw2 & encodings.hw2_mask != encodings.hw2) return null;
    return .{
        .qd = @intCast(instr.hw2 >> 13 & 7),
        .qm = @intCast(instr.hw2 >> 1 & 7),
        .widen = instr.hw1 >> 12 & 1 == 1,
        .top = instr.hw2 >> 12 & 1 == 1,
    };
}

fn decode(instr: Instr) ?op.Exec {
    _ = fields(instr) orelse return null;
    return run;
}

fn run(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = fields(instr).?;
    const bank = &cpu.fp.bank;
    const old = mve.qreg.read(bank, f.qd);
    const m = mve.qreg.read(bank, f.qm);
    const mask = mve_beats.mask(cpu);
    const result = if (f.widen)
        mve.float.cvt.fromHalf(old, m, f.top, mask, &cpu.fp.fpscr)
    else
        mve.float.cvt.toHalf(old, m, f.top, mask, &cpu.fp.fpscr);
    mve.qreg.write(bank, f.qd, result);
    mve_beats.finish(cpu);
}
