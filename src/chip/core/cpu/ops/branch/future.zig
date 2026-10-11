//! Armv8.1-M Branch Future requests. This core has no LO_BRANCH_INFO branch
//! cache, so it takes the DDI0553-permitted NOP implementation. Firmware keeps
//! ordinary fallback branches at each branch point; those perform the branch
//! and set LR for BFL/BFLX when they run.
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;

pub const encodings = struct {
    pub const hw1_mask: u16 = 0xF800;
    pub const hw1: u16 = 0xF000;
    pub const boff_mask: u16 = 0x0780;
    pub const bfl_hw2: u16 = 0xC000;
    pub const other_hw2: u16 = 0xE000;
    pub const reg_hw2: u16 = 0xE001;
};

pub const group: op.Group = .{ .name = "branch_future", .decode = decode };

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4 or instr.hw1 & encodings.hw1_mask != encodings.hw1) return null;
    if (instr.hw1 & encodings.boff_mask == 0 or instr.hw2 & 1 == 0) return null;

    if (instr.hw2 & 0xF000 == encodings.bfl_hw2) return complete;
    if (instr.hw2 & 0xF000 != encodings.other_hw2) return null;

    const form = instr.hw1 & 0x0060;
    if (form == 0x0060) {
        if (instr.hw2 != encodings.reg_hw2) return null;
        return complete;
    }
    if (form == 0x0040 or instr.hw1 & 0x0040 == 0) return complete;
    return null;
}

fn complete(cpu: *Cpu, instr: Instr) op.Error!void {
    _ = cpu;
    _ = instr;
}
