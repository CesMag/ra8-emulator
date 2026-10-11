//! 16-bit ADD and SUB with a register or a 3-bit immediate (T1), and MOV,
//! CMP, ADD and SUB with an 8-bit immediate (T1/T1/T2/T2). CMP always sets
//! the flags; the rest set them only outside an IT block. MOV sets N and Z
//! and leaves C and V.
const op = @import("../../../op.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;
const flags = @import("../../../flags.zig");
pub const wide = @import("wide.zig");

pub const encodings = struct {
    pub const three_mask: u16 = 0xFE00;
    pub const add_reg: u16 = 0x1800;
    pub const sub_reg: u16 = 0x1A00;
    pub const add_imm3: u16 = 0x1C00;
    pub const sub_imm3: u16 = 0x1E00;
    pub const imm8_mask: u16 = 0xF800;
    pub const mov_imm8: u16 = 0x2000;
    pub const cmp_imm8: u16 = 0x2800;
    pub const add_imm8: u16 = 0x3000;
    pub const sub_imm8: u16 = 0x3800;
};

pub const group: op.Group = .{ .name = "add_sub", .decode = decode };

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 2) return null;
    const e = encodings;
    switch (instr.hw1 & e.three_mask) {
        e.add_reg, e.sub_reg, e.add_imm3, e.sub_imm3 => return threeOperand,
        else => {},
    }
    return switch (instr.hw1 & e.imm8_mask) {
        e.mov_imm8 => movImm8,
        e.cmp_imm8 => cmpImm8,
        e.add_imm8, e.sub_imm8 => arithImm8,
        else => null,
    };
}

/// Rn + y, or Rn - y as Rn + NOT(y) + 1.
fn addOrSub(x: u32, y: u32, subtract: bool) flags.Sum {
    return if (subtract) flags.addWithCarry(x, ~y, true) else flags.addWithCarry(x, y, false);
}

fn threeOperand(cpu: *Cpu, instr: Instr) op.Error!void {
    const hw1 = instr.hw1;
    const field: u32 = (hw1 >> 6) & 0x7;
    const y = if (hw1 & 0x0400 != 0) field else cpu.regs.get(@intCast(field));
    const rn: u4 = @intCast((hw1 >> 3) & 0x7);
    const sum = addOrSub(cpu.regs.get(rn), y, hw1 & 0x0200 != 0);
    cpu.regs.set(@intCast(hw1 & 0x7), sum.result);
    if (!flags.inItBlock(&cpu.regs)) flags.setNZCV(&cpu.regs, sum);
}

fn rdn(hw1: u16) u4 {
    return @intCast((hw1 >> 8) & 0x7);
}

fn movImm8(cpu: *Cpu, instr: Instr) op.Error!void {
    const value: u32 = instr.hw1 & 0xFF;
    cpu.regs.set(rdn(instr.hw1), value);
    if (!flags.inItBlock(&cpu.regs)) flags.setNZ(&cpu.regs, value);
}

fn cmpImm8(cpu: *Cpu, instr: Instr) op.Error!void {
    flags.setNZCV(&cpu.regs, addOrSub(cpu.regs.get(rdn(instr.hw1)), instr.hw1 & 0xFF, true));
}

fn arithImm8(cpu: *Cpu, instr: Instr) op.Error!void {
    const rd = rdn(instr.hw1);
    const sum = addOrSub(cpu.regs.get(rd), instr.hw1 & 0xFF, instr.hw1 & 0x0800 != 0);
    cpu.regs.set(rd, sum.result);
    if (!flags.inItBlock(&cpu.regs)) flags.setNZCV(&cpu.regs, sum);
}
