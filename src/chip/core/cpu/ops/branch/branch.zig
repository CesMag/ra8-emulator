//! 16-bit B<cond> (T1) and B (T2). Both branch relative to the PC the
//! instruction sees, its own address plus 4. Conditions 0b1110 and 0b1111 of
//! the T1 space are UDF and SVC, which are not branches.
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;
const cond = @import("../../cond.zig");
pub const future = @import("future.zig");
pub const wide = @import("wide.zig");

pub const encodings = struct {
    pub const cond_mask: u16 = 0xF000;
    pub const b_cond: u16 = 0xD000;
    pub const b_mask: u16 = 0xF800;
    pub const b: u16 = 0xE000;
};

pub const group: op.Group = .{ .name = "branch", .decode = decode };

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 2) return null;
    if (instr.hw1 & encodings.b_mask == encodings.b) return always;
    if (instr.hw1 & encodings.cond_mask != encodings.b_cond) return null;
    if ((instr.hw1 >> 9) & 0x7 == 0x7) return null; // cond 0b111x: UDF, SVC
    return conditional;
}

fn target(address: u32, offset: i32) u32 {
    return address +% 4 +% @as(u32, @bitCast(offset));
}

fn conditional(cpu: *Cpu, instr: Instr) op.Error!void {
    const c: u4 = @intCast((instr.hw1 >> 8) & 0xF);
    if (!cond.passed(c, cpu.regs.xpsr)) return;
    const imm8: i8 = @bitCast(@as(u8, @truncate(instr.hw1)));
    cpu.regs.pc = target(instr.address, @as(i32, imm8) * 2);
}

fn always(cpu: *Cpu, instr: Instr) op.Error!void {
    const imm11: i11 = @bitCast(@as(u11, @truncate(instr.hw1)));
    cpu.regs.pc = target(instr.address, @as(i32, imm11) * 2);
}
