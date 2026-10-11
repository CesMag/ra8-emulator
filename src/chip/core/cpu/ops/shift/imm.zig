//! LSL, LSR and ASR by an immediate, 16-bit (T1/T2/T2). LSL #0 is MOV Rd, Rm
//! (T2). Outside an IT block they set N, Z and C (C only when something was
//! shifted); inside one they leave the flags alone.
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;
const flags = @import("../../flags.zig");
const shift = @import("../../shift.zig");

pub const encodings = struct {
    /// Bits [15:13] are zero and [12:11] pick the shift; 0b11 is ADD/SUB.
    pub const mask: u16 = 0xE000;
    pub const shift_imm: u16 = 0x0000;
    pub const add_sub: u16 = 0x1800;
};

pub const group: op.Group = .{ .name = "shift_imm", .decode = decode };

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 2 or instr.hw1 & encodings.mask != encodings.shift_imm) return null;
    if (instr.hw1 & encodings.add_sub == encodings.add_sub) return null;
    return exec;
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const kind: shift.Kind = @fromBackingInt(@intCast((instr.hw1 >> 11) & 0x3));
    const imm5: u5 = @intCast((instr.hw1 >> 6) & 0x1F);
    const rm: u4 = @intCast((instr.hw1 >> 3) & 0x7);
    const rd: u4 = @intCast(instr.hw1 & 0x7);
    const out = shift.shiftC(cpu.regs.get(rm), kind, shift.immAmount(kind, imm5), flags.carry(&cpu.regs));
    cpu.regs.set(rd, out.result);
    if (!flags.inItBlock(&cpu.regs)) flags.setNZC(&cpu.regs, out.result, out.carry);
}
