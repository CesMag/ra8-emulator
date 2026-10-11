//! The 32-bit branches: B<cond>.W (T3), B.W (T4) and BL (T1). Each branches
//! relative to its own address plus 4. BL also leaves that return address,
//! with bit 0 set for Thumb, in LR.
//!
//! T3 conditions 0b111x encode the miscellaneous control space (MSR, MRS,
//! hints, barriers), which is not a branch and is left to its own group.
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;
const cond = @import("../../cond.zig");

pub const encodings = struct {
    pub const hw1_mask: u16 = 0xF800;
    pub const hw1: u16 = 0xF000;
    /// hw2 bits [15:14] and [12] pick the form.
    pub const hw2_mask: u16 = 0xD000;
    pub const b_cond: u16 = 0x8000;
    pub const b: u16 = 0x9000;
    pub const bl: u16 = 0xD000;
};

pub const group: op.Group = .{ .name = "branch_wide", .decode = decode };

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4 or instr.hw1 & encodings.hw1_mask != encodings.hw1) return null;
    return switch (instr.hw2 & encodings.hw2_mask) {
        encodings.bl => bl,
        encodings.b => always,
        encodings.b_cond => if ((instr.hw1 >> 7) & 0x7 == 0x7) null else conditional,
        else => null,
    };
}

fn bit(value: u16, n: u4) u32 {
    return (value >> n) & 1;
}

/// T4 and BL: S:I1:I2:imm10:imm11:'0', where In is NOT(Jn XOR S).
pub fn offset24(instr: Instr) i32 {
    const s = bit(instr.hw1, 10);
    const in1 = ~(bit(instr.hw2, 13) ^ s) & 1;
    const in2 = ~(bit(instr.hw2, 11) ^ s) & 1;
    const imm10: u32 = instr.hw1 & 0x3FF;
    const imm11: u32 = instr.hw2 & 0x7FF;
    const raw: u25 = @intCast((s << 24) | (in1 << 23) | (in2 << 22) | (imm10 << 12) | (imm11 << 1));
    return @as(i25, @bitCast(raw));
}

/// T3: S:J2:J1:imm6:imm11:'0'.
pub fn offset20(instr: Instr) i32 {
    const s = bit(instr.hw1, 10);
    const j1 = bit(instr.hw2, 13);
    const j2 = bit(instr.hw2, 11);
    const imm6: u32 = instr.hw1 & 0x3F;
    const imm11: u32 = instr.hw2 & 0x7FF;
    const raw: u21 = @intCast((s << 20) | (j2 << 19) | (j1 << 18) | (imm6 << 12) | (imm11 << 1));
    return @as(i21, @bitCast(raw));
}

fn target(address: u32, offset: i32) u32 {
    return address +% 4 +% @as(u32, @bitCast(offset));
}

fn bl(cpu: *Cpu, instr: Instr) op.Error!void {
    cpu.regs.lr = (instr.address +% 4) | 1;
    cpu.regs.pc = target(instr.address, offset24(instr));
}

fn always(cpu: *Cpu, instr: Instr) op.Error!void {
    cpu.regs.pc = target(instr.address, offset24(instr));
}

fn conditional(cpu: *Cpu, instr: Instr) op.Error!void {
    const c: u4 = @intCast((instr.hw1 >> 6) & 0xF);
    if (!cond.passed(c, cpu.regs.xpsr)) return;
    cpu.regs.pc = target(instr.address, offset20(instr));
}
