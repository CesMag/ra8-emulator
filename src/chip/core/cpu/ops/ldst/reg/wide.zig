//! Load and store with a shifted register offset, 32-bit (T2): STR/STRH/STRB,
//! LDR/LDRH/LDRB and LDRSB/LDRSH [Rn, Rm, LSL #imm2]. No writeback. An
//! unaligned word or halfword goes through as bytes, the behaviour with
//! CCR.UNALIGN_TRP clear; with it set the core stops (RA8EMU-85).
//!
//! Left unclaimed: Rn = PC (the literal forms), Rm of SP or PC, a store of PC,
//! and Rt of SP or PC on a byte or halfword access (Rt = PC there is PLD, PLI
//! or an unallocated hint). LDR with Rt = PC branches through BXWritePC.
const std = @import("std");
const op = @import("../../../op.zig");
const alignment = @import("../../../alignment.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;
const bti = @import("../../../bti.zig");

pub const encodings = struct {
    /// hw1 with Rn ([3:0]) masked out.
    pub const mask: u16 = 0xFFF0;
    pub const strb: u16 = 0xF800;
    pub const ldrb: u16 = 0xF810;
    pub const strh: u16 = 0xF820;
    pub const ldrh: u16 = 0xF830;
    pub const str: u16 = 0xF840;
    pub const ldr: u16 = 0xF850;
    pub const ldrsb: u16 = 0xF910;
    pub const ldrsh: u16 = 0xF930;
    /// hw2[11:6] is zero in the register-offset forms.
    pub const hw2_zero: u16 = 0x0FC0;
};

pub const group: op.Group = .{ .name = "ldst_reg_wide", .decode = decode };

pub const Fields = struct {
    load: bool,
    /// 1, 2 or 4 bytes.
    size: u3,
    signed: bool,
    rn: u4,
    rt: u4,
    rm: u4,
    shift: u5,

    pub fn of(instr: Instr) ?Fields {
        if (instr.size != 4 or instr.hw2 & encodings.hw2_zero != 0) return null;
        const kind = instr.hw1 & encodings.mask;
        const size: u3 = switch (kind) {
            encodings.str, encodings.ldr => 4,
            encodings.strh, encodings.ldrh, encodings.ldrsh => 2,
            encodings.strb, encodings.ldrb, encodings.ldrsb => 1,
            else => return null,
        };
        return .{
            .load = kind & 0x10 != 0,
            .size = size,
            .signed = kind == encodings.ldrsb or kind == encodings.ldrsh,
            .rn = @intCast(instr.hw1 & 0xF),
            .rt = @intCast(instr.hw2 >> 12),
            .rm = @intCast(instr.hw2 & 0xF),
            .shift = @intCast((instr.hw2 >> 4) & 0x3),
        };
    }

    pub fn address(self: Fields, cpu: *const Cpu) u32 {
        return cpu.regs.get(self.rn) +% (cpu.regs.get(self.rm) << self.shift);
    }
};

fn decode(instr: Instr) ?op.Exec {
    const f = Fields.of(instr) orelse return null;
    if (f.rn == 15 or f.rm == 13 or f.rm == 15) return null;
    if (f.size == 4) {
        if (!f.load and f.rt == 15) return null;
    } else if (f.rt == 13 or f.rt == 15) return null;
    return if (f.load) load else store;
}

fn store(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = Fields.of(instr).?;
    const address = f.address(cpu);
    try alignment.memU(cpu.bus, address, f.size);
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, cpu.regs.get(f.rt), .little);
    try cpu.bus.write(address, bytes[0..f.size]);
}

fn load(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = Fields.of(instr).?;
    const address = f.address(cpu);
    try alignment.memU(cpu.bus, address, f.size);
    var bytes = @as([4]u8, @splat(0));
    try cpu.bus.read(address, bytes[0..f.size]);
    var value = std.mem.readInt(u32, &bytes, .little);
    if (f.signed) {
        const top: u5 = @intCast(@as(u6, f.size) * 8 - 1);
        if ((value >> top) & 1 != 0) value |= ~@as(u32, 0) << top;
    }
    if (f.rt == 15) {
        cpu.regs.bxWritePc(value);
        if (cpu.regs.exc_return == null) bti.setForAddress(&cpu.regs, cpu.profile.v8_1m);
        return;
    }
    cpu.regs.set(f.rt, value);
}
