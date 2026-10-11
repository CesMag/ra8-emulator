//! MVE VCMP and VPT, integer forms T1-T6 (RA8EMU-25). hw1 is 1111 1110 0
//! M size Qn 1 and hw2 is mask[2:0] S 1111 fc1 R x 0 Qm:fc0 (vector, R=0,
//! x=0) or Rm (scalar, R=1, x=fc0), per LLVM's assembler. A zero block
//! mask is VCMP; any other is VPT, which opens a block with that mask once
//! the compare has written P0. As QEMU's do_vcmp reads the pseudocode, P0
//! takes the compare ANDed with the current element mask, then the block
//! advances. Size 3 is VPNOT, VPSEL and VPST, and the FP compares have
//! hw1 0xEE31 or 0xFE31, so neither is claimed. Rm of SP or PC is left
//! unclaimed. Lane semantics are in src/chip/core/cpu/mve/compare/compare.zig.
const op = @import("../../../op.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;
const mve = @import("../../../mve/all.zig");
const mve_beats = @import("../beats.zig");
const vpst = @import("../vpst.zig");
const scalar_ops = @import("../int/scalar.zig");
pub const fp = @import("fp.zig");
const Size = mve.qreg.Size;

pub const group: op.Group = .{ .name = "mve_vcmp", .decode = decode, .oracle = false };

pub const encodings = struct {
    /// hw1 with M (6), size (5:4) and Qn (3:1) masked out.
    pub const hw1_mask: u16 = 0xFF81;
    pub const hw1: u16 = 0xFE01;
    /// hw2's fixed bits 11:8 and 4.
    pub const hw2_mask: u16 = 0x0F10;
    pub const hw2: u16 = 0x0F00;
    pub const scalar_bit: u16 = 0x0040;
};

/// The fields one VCMP or VPT encoding names.
pub const Fields = struct { qn: u3, qm: u3, rm: u4, scalar: bool, size: Size, cond: mve.compare.Cond, mask: u4 };

pub fn fields(instr: Instr) ?Fields {
    if (instr.size != 4 or instr.hw1 & encodings.hw1_mask != encodings.hw1) return null;
    if (instr.hw2 & encodings.hw2_mask != encodings.hw2) return null;
    const size = instr.hw1 >> 4 & 3;
    if (size == 3) return null;
    const scalar = instr.hw2 & encodings.scalar_bit != 0;
    const rm: u4 = @intCast(instr.hw2 & 0xF);
    if (scalar and (rm == 13 or rm == 15)) return null;
    if (!scalar and instr.hw2 & 0x0020 != 0) return null;
    const fc0 = if (scalar) instr.hw2 & 0x0020 != 0 else instr.hw2 & 1 != 0;
    return .{
        .qn = @intCast(instr.hw1 >> 1 & 7),
        .qm = @intCast(instr.hw2 >> 1 & 7),
        .rm = rm,
        .scalar = scalar,
        .size = @fromBackingInt(@intCast(size)),
        .cond = mve.compare.condOf(instr.hw2 & 0x1000 != 0, fc0, instr.hw2 & 0x0080 != 0),
        .mask = vpst.mask(instr),
    };
}

fn decode(instr: Instr) ?op.Exec {
    _ = fields(instr) orelse return null;
    return run;
}

fn run(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = fields(instr).?;
    const a = mve.qreg.read(&cpu.fp.bank, f.qn);
    const b = if (f.scalar) scalar_ops.splat(cpu.regs.get(f.rm), f.size) else mve.qreg.read(&cpu.fp.bank, f.qm);
    const pending = mve_beats.pending(cpu);
    const done = ~pending;
    cpu.fp.vpr.p0 = (cpu.fp.vpr.p0 & done) | (mve.compare.compare(a, b, f.size, f.cond) & mve_beats.mask(cpu));
    mve_beats.finish(cpu);
    if (f.mask != 0) cpu.fp.vpr = mve.vpt.openBeats(cpu.fp.vpr, f.mask, pending);
}
