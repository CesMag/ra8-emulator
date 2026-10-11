//! VPST (T1): opens a VPT block by writing its mask into VPR.MASK01 and
//! MASK23 (src/chip/core/cpu/mve/vpt.zig). hw1 is 1111 1110 0 M 11 0001 and
//! hw2 is mask[2:0] 0 1111 0100 1101, with M as mask[3]. A zero mask is a
//! different encoding and stays unclaimed. Each predicated MVE instruction
//! advances the block itself when it retires.
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;
const vpt = @import("../../mve/vpt.zig");
const mve_beats = @import("beats.zig");

pub const group: op.Group = .{ .name = "mve_vpst", .decode = decode, .oracle = false };

pub const encodings = struct {
    /// hw1 with M (bit 6) masked out.
    pub const vpst_hw1: u16 = 0xFE31;
    /// hw2 with mask[2:0] (bits 15:13) masked out.
    pub const vpst_hw2: u16 = 0x0F4D;
};

/// The 4-bit block mask, M:hw2[15:13].
pub fn mask(instr: Instr) u4 {
    return @intCast((instr.hw1 >> 6 & 1) << 3 | instr.hw2 >> 13);
}

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4) return null;
    if (instr.hw1 & 0xFFBF != encodings.vpst_hw1) return null;
    if (instr.hw2 & 0x1FFF != encodings.vpst_hw2) return null;
    if (mask(instr) == 0) return null;
    return run;
}

fn run(cpu: *Cpu, instr: Instr) op.Error!void {
    const pending = mve_beats.pending(cpu);
    cpu.fp.vpr = vpt.openBeats(cpu.fp.vpr, mask(instr), pending);
    mve_beats.finishEci(cpu);
}
