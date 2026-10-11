//! Load and store multiple, 16-bit (T1): STM Rn!, {list} and LDM Rn{!},
//! {list}, increment after, over r0..r7.
//!
//! Registers go lowest-numbered at the lowest address. An empty list is
//! UNPREDICTABLE, so the group leaves it unclaimed. STM always writes back.
//! LDM writes back only when Rn is not in the list; when it is, the loaded
//! value wins. STM with Rn in the list stores Rn's value before the
//! instruction.
const std = @import("std");
const op = @import("../../../op.zig");
const alignment = @import("../../../alignment.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;
pub const wide = @import("wide.zig");

pub const encodings = struct {
    /// Bits [15:11] of the first halfword.
    pub const mask: u16 = 0xF800;
    pub const stm_t1: u16 = 0xC000;
    pub const ldm_t1: u16 = 0xC800;
};

pub const group: op.Group = .{ .name = "ldm_stm", .decode = decode };

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 2 or instr.hw1 & 0xFF == 0) return null;
    return switch (instr.hw1 & encodings.mask) {
        encodings.stm_t1 => stm,
        encodings.ldm_t1 => ldm,
        else => null,
    };
}

/// The base register, bits [10:8].
pub fn base(hw1: u16) u4 {
    return @intCast((hw1 >> 8) & 7);
}

fn stm(cpu: *Cpu, instr: Instr) op.Error!void {
    const rn = base(instr.hw1);
    const registers: u8 = @truncate(instr.hw1);
    var address = cpu.regs.get(rn);
    try alignment.memA(address, 4);
    for (0..8) |i| {
        if (registers & (@as(u8, 1) << @intCast(i)) == 0) continue;
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, cpu.regs.get(@intCast(i)), .little);
        try cpu.bus.write(address, &bytes);
        address +%= 4;
    }
    cpu.regs.set(rn, address);
}

fn ldm(cpu: *Cpu, instr: Instr) op.Error!void {
    const rn = base(instr.hw1);
    const registers: u8 = @truncate(instr.hw1);
    var values: [8]u32 = undefined;
    var address = cpu.regs.get(rn);
    try alignment.memA(address, 4);
    for (0..8) |i| {
        if (registers & (@as(u8, 1) << @intCast(i)) == 0) continue;
        values[i] = try cpu.bus.readWord(address);
        address +%= 4;
    }
    if (registers & (@as(u8, 1) << @intCast(rn)) == 0) cpu.regs.set(rn, address);
    for (0..8) |i| {
        if (registers & (@as(u8, 1) << @intCast(i)) != 0) cpu.regs.set(@intCast(i), values[i]);
    }
}
