//! LSL, LSR, ASR and ROR by a register, 32-bit (T2): Rd = Rn shifted by the
//! bottom byte of Rm. With S set they write N, Z and C (C only when the
//! amount is non-zero, as Shift_C leaves it otherwise).
//!
//! SP or PC in any register field is UNPREDICTABLE and left unclaimed.
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;
const flags = @import("../../flags.zig");
const shift = @import("../../shift.zig");

pub const encodings = struct {
    /// hw1[15:7] = 0b111110100, then type, S and Rn.
    pub const hw1_mask: u16 = 0xFF80;
    pub const hw1_space: u16 = 0xFA00;
    /// hw2 = 0b1111 Rd 0b0000 Rm.
    pub const hw2_mask: u16 = 0xF0F0;
    pub const hw2_space: u16 = 0xF000;
};

pub const group: op.Group = .{ .name = "shift_reg", .decode = decode };

pub const Fields = struct {
    kind: shift.Kind,
    s: bool,
    rn: u4,
    rd: u4,
    rm: u4,

    pub fn of(instr: Instr) ?Fields {
        if (instr.size != 4 or instr.hw1 & encodings.hw1_mask != encodings.hw1_space) return null;
        if (instr.hw2 & encodings.hw2_mask != encodings.hw2_space) return null;
        return .{
            .kind = @fromBackingInt(@intCast((instr.hw1 >> 5) & 0x3)),
            .s = instr.hw1 & 0x10 != 0,
            .rn = @intCast(instr.hw1 & 0xF),
            .rd = @intCast((instr.hw2 >> 8) & 0xF),
            .rm = @intCast(instr.hw2 & 0xF),
        };
    }
};

fn spOrPc(n: u4) bool {
    return n == 13 or n == 15;
}

fn decode(instr: Instr) ?op.Exec {
    const f = Fields.of(instr) orelse return null;
    if (spOrPc(f.rd) or spOrPc(f.rn) or spOrPc(f.rm)) return null;
    return exec;
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = Fields.of(instr).?;
    const amount = cpu.regs.get(f.rm) & 0xFF;
    const out = shift.shiftC(cpu.regs.get(f.rn), f.kind, amount, flags.carry(&cpu.regs));
    cpu.regs.set(f.rd, out.result);
    if (f.s) flags.setNZC(&cpu.regs, out.result, out.carry);
}
