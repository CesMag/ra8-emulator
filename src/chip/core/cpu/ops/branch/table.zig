//! TBB and TBH (T1): branch forward by twice an unsigned byte or halfword read
//! from a table at Rn + Rm (TBB) or Rn + Rm * 2 (TBH). Rn may be the PC, which
//! reads as the instruction's address plus 4, so a table can sit straight
//! after the instruction. Rn = SP and Rm = SP or PC are UNPREDICTABLE and are
//! left unclaimed.
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;

pub const encodings = struct {
    pub const hw1_mask: u16 = 0xFFF0;
    pub const hw1: u16 = 0xE8D0;
    pub const hw2_mask: u16 = 0xFFE0;
    pub const hw2: u16 = 0xF000;
    /// Set for TBH.
    pub const half: u16 = 1 << 4;
};

const sp: u16 = 13;
const pc: u16 = 15;

pub const group: op.Group = .{ .name = "table_branch", .decode = decode };

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4) return null;
    if (instr.hw1 & encodings.hw1_mask != encodings.hw1) return null;
    if (instr.hw2 & encodings.hw2_mask != encodings.hw2) return null;
    const rn = instr.hw1 & 0xF;
    const rm = instr.hw2 & 0xF;
    if (rn == sp or rm == sp or rm == pc) return null;
    return run;
}

pub fn isHalf(instr: Instr) bool {
    return instr.hw2 & encodings.half != 0;
}

/// Where the table entry the instruction reads sits.
pub fn entry(cpu: *const Cpu, instr: Instr) u32 {
    const rn: u4 = @intCast(instr.hw1 & 0xF);
    const rm: u4 = @intCast(instr.hw2 & 0xF);
    const base = if (rn == pc) instr.address +% 4 else cpu.regs.get(rn);
    const index = cpu.regs.get(rm);
    return base +% if (isHalf(instr)) index << 1 else index;
}

fn run(cpu: *Cpu, instr: Instr) op.Error!void {
    const at = entry(cpu, instr);
    var halfwords: u32 = undefined;
    if (isHalf(instr)) {
        halfwords = try cpu.bus.readHalf(at);
    } else {
        var byte: [1]u8 = undefined;
        try cpu.bus.read(at, &byte);
        halfwords = byte[0];
    }
    cpu.regs.pc = instr.address +% 4 +% (halfwords << 1);
}
