//! MVE VPNOT and VPSEL (T1), the two instructions that work on P0 itself
//! (RA8EMU-25). Encodings per LLVM's assembler: VPNOT is exactly
//! 0xFE31 0x0F4D (VPST's space with a zero mask); VPSEL is hw1 1111 1110
//! 0 D 11 Qn 1 and hw2 Qd 0 1111 0 N 0 M 0 Qm 1. Following QEMU's helpers:
//! VPNOT writes P0 as NOT P0 ANDed with the element mask (the VCMP rule),
//! and VPSEL picks each byte from Qn where P0 is set and from Qm where it
//! is clear, reading raw P0 rather than the element mask. Both then advance
//! the VPT block.
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;
const mve = @import("../../mve/all.zig");
const mve_beats = @import("beats.zig");

pub const group: op.Group = .{ .name = "mve_vpred", .decode = decode, .oracle = false };

pub const encodings = struct {
    pub const vpnot_hw1: u16 = 0xFE31;
    pub const vpnot_hw2: u16 = 0x0F4D;
    /// VPSEL with D, Qn, Qd, N, M and Qm masked out.
    pub const vpsel_hw1_mask: u16 = 0xFFF1;
    pub const vpsel_hw1: u16 = 0xFE31;
    pub const vpsel_hw2_mask: u16 = 0x1FF1;
    pub const vpsel_hw2: u16 = 0x0F01;
};

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4) return null;
    const e = encodings;
    if (instr.hw1 == e.vpnot_hw1 and instr.hw2 == e.vpnot_hw2) return vpnot;
    if (instr.hw1 & e.vpsel_hw1_mask == e.vpsel_hw1 and instr.hw2 & e.vpsel_hw2_mask == e.vpsel_hw2) return vpsel;
    return null;
}

fn vpnot(cpu: *Cpu, _: Instr) op.Error!void {
    const done = ~mve_beats.pending(cpu);
    cpu.fp.vpr.p0 = (cpu.fp.vpr.p0 & done) | (~cpu.fp.vpr.p0 & mve_beats.mask(cpu));
    mve_beats.finish(cpu);
}

fn vpsel(cpu: *Cpu, instr: Instr) op.Error!void {
    const qd: u3 = @intCast(instr.hw2 >> 13);
    const n = mve.qreg.read(&cpu.fp.bank, @intCast(instr.hw1 >> 1 & 7));
    const m = mve.qreg.read(&cpu.fp.bank, @intCast(instr.hw2 >> 1 & 7));
    mve_beats.keep(cpu, qd, mve.predicate.merge(m, n, cpu.fp.vpr.p0));
    mve_beats.finish(cpu);
}
