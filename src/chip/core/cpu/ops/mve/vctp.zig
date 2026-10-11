//! VCTP (RA8EMU-236): create a tail predicate. P0 gets the first Rn
//! elements of the given size set, ANDed with the predicate in force, over
//! the beats this instruction runs; VPT then advances like any MVE
//! instruction. The arithmetic is mve/tail.zig's vctp.
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;
const tail = @import("../../mve/all.zig").tail;
const mve_beats = @import("beats.zig");

pub const encodings = struct {
    /// 0xF0sn 0xE801: s the element size, n Rn.
    pub const first_mask: u16 = 0xFFC0;
    pub const first: u16 = 0xF000;
    pub const second: u16 = 0xE801;
    pub const size_shift: u4 = 4;
    pub const rn_mask: u16 = 0x000F;
    pub const sp: u4 = 13;
    pub const pc: u4 = 15;
};

pub const Fields = struct { size: u2, rn: u4 };

pub const group: op.Group = .{ .name = "mve_vctp", .decode = decode, .oracle = false };

/// The decoded VCTP, or null when this group does not claim it. SP and PC
/// as Rn are UNPREDICTABLE and refused.
pub fn fields(instr: Instr) ?Fields {
    const e = encodings;
    if (instr.size != 4 or instr.hw2 != e.second) return null;
    if (instr.hw1 & e.first_mask != e.first) return null;
    const rn: u4 = @truncate(instr.hw1 & e.rn_mask);
    if (rn == e.sp or rn == e.pc) return null;
    return .{ .size = @truncate(instr.hw1 >> e.size_shift), .rn = rn };
}

fn decode(instr: Instr) ?op.Exec {
    _ = fields(instr) orelse return null;
    return exec;
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = fields(instr).?;
    const rn = cpu.regs.get(f.rn);
    cpu.fp.vpr = tail.vctp(cpu.fp.vpr, f.size, rn, mve_beats.mask(cpu), mve_beats.pending(cpu));
    mve_beats.finish(cpu);
}
