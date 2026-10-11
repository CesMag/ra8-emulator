//! MVE VCMP and VPT on F16 and F32 lanes, vector (T1) and by scalar (T2)
//! (RA8EMU-23). hw1 is 111s 1110 0 M 11 Qn 1, with s=1 for F16, and hw2 is
//! mask[2:0] fc2 1111 fc1 R x 0 Qm:fc0 (vector, R=0, x=0) or Rm (scalar,
//! R=1, x=fc0), per QEMU's mve.decode and LLVM's assembler. fc2:fc0:fc1
//! picks EQ, NE, GE, LT, GT or LE; fc2=0 with fc0=1 has no float meaning
//! and is left unclaimed, as is Rm of SP or PC. A zero block mask is VCMP;
//! any other is VPT, which opens a block once P0 is written. The integer
//! group rejects these because their size field reads 0b11. Lane semantics
//! are in src/chip/core/cpu/mve/float.cmp.zig.
const op = @import("../../../op.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;
const mve = @import("../../../mve/all.zig");
const mve_beats = @import("../beats.zig");
const vpst = @import("../vpst.zig");
const Cond = mve.float.cmp.Cond;

pub const group: op.Group = .{ .name = "mve_vcmp_fp", .decode = decode, .oracle = false };

pub const encodings = struct {
    /// hw1 with s (12), M (6) and Qn (3:1) masked out.
    pub const hw1_mask: u16 = 0xEFB1;
    pub const hw1: u16 = 0xEE31;
    /// hw2's fixed bits 11:8 and 4.
    pub const hw2_mask: u16 = 0x0F10;
    pub const hw2: u16 = 0x0F00;
    pub const scalar_bit: u16 = 0x0040;
};

/// The fields one VCMP or VPT encoding names.
pub const Fields = struct { qn: u3, qm: u3, rm: u4, scalar: bool, size: mve.float.Size, cond: Cond, mask: u4 };

pub fn fields(instr: Instr) ?Fields {
    if (instr.size != 4 or instr.hw1 & encodings.hw1_mask != encodings.hw1) return null;
    if (instr.hw2 & encodings.hw2_mask != encodings.hw2) return null;
    const scalar = instr.hw2 & encodings.scalar_bit != 0;
    const rm: u4 = @intCast(instr.hw2 & 0xF);
    if (scalar and (rm == 13 or rm == 15)) return null;
    if (!scalar and instr.hw2 & 0x0020 != 0) return null;
    const fc0 = if (scalar) instr.hw2 & 0x0020 != 0 else instr.hw2 & 1 != 0;
    const cond = condOf(instr.hw2 & 0x1000 != 0, fc0, instr.hw2 & 0x0080 != 0) orelse return null;
    return .{
        .qn = @intCast(instr.hw1 >> 1 & 7),
        .qm = @intCast(instr.hw2 >> 1 & 7),
        .rm = rm,
        .scalar = scalar,
        .size = if (instr.hw1 >> 12 & 1 == 1) .half else .word,
        .cond = cond,
        .mask = vpst.mask(instr),
    };
}

/// The condition fc2, fc0 and fc1 name, or null for fc2=0 with fc0=1.
pub fn condOf(fc2: bool, fc0: bool, fc1: bool) ?Cond {
    if (!fc2) return if (fc0) null else if (fc1) .ne else .eq;
    if (fc0) return if (fc1) .le else .gt;
    return if (fc1) .lt else .ge;
}

fn decode(instr: Instr) ?op.Exec {
    _ = fields(instr) orelse return null;
    return run;
}

fn run(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = fields(instr).?;
    const bank = &cpu.fp.bank;
    const n = mve.qreg.read(bank, f.qn);
    const mask = mve_beats.mask(cpu);
    const p0 = if (f.scalar)
        mve.float.scalar.compare(n, cpu.regs.get(f.rm), f.size, f.cond, mask, &cpu.fp.fpscr)
    else
        mve.float.cmp.compare(n, mve.qreg.read(bank, f.qm), f.size, f.cond, mask, &cpu.fp.fpscr);
    const pending = mve_beats.pending(cpu);
    const done = ~pending;
    cpu.fp.vpr.p0 = (cpu.fp.vpr.p0 & done) | p0;
    mve_beats.finish(cpu);
    if (f.mask != 0) cpu.fp.vpr = mve.vpt.openBeats(cpu.fp.vpr, f.mask, pending);
}
