//! LDR Rt, [PC, #imm8] (T1): a word from the literal pool. The address is
//! Align(PC, 4) + imm8 * 4, where PC reads as the instruction's address
//! plus 4. Rt is r0-r7, so this encoding never loads the PC.
const op = @import("../../../op.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;
pub const wide = @import("wide.zig");

pub const encodings = struct {
    pub const mask: u16 = 0xF800;
    pub const ldr_literal_t1: u16 = 0x4800;
};

pub const group: op.Group = .{ .name = "ldr_literal", .decode = decode };

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 2 or instr.hw1 & encodings.mask != encodings.ldr_literal_t1) return null;
    return load;
}

/// Where the literal sits.
pub fn address(instr: Instr) u32 {
    const base = (instr.address +% 4) & ~@as(u32, 3);
    return base +% (@as(u32, instr.hw1 & 0xFF) << 2);
}

fn load(cpu: *Cpu, instr: Instr) op.Error!void {
    const rt: u4 = @intCast((instr.hw1 >> 8) & 0x7);
    cpu.regs.set(rt, try cpu.bus.readWord(address(instr)));
}
