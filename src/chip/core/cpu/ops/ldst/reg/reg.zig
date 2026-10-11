//! Load and store with a register offset, 16-bit: STR/STRH/STRB,
//! LDR/LDRH/LDRB and the sign-extending LDRSB/LDRSH [Rn, Rm] (T1). No shift
//! and no writeback. An unaligned word or halfword goes through as bytes, the
//! behaviour with CCR.UNALIGN_TRP clear; with it set the core stops (RA8EMU-85).
const std = @import("std");
const op = @import("../../../op.zig");
const alignment = @import("../../../alignment.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;
pub const wide = @import("wide.zig");

pub const encodings = struct {
    pub const mask: u16 = 0xFE00;
    pub const str: u16 = 0x5000;
    pub const strh: u16 = 0x5200;
    pub const strb: u16 = 0x5400;
    pub const ldrsb: u16 = 0x5600;
    pub const ldr: u16 = 0x5800;
    pub const ldrh: u16 = 0x5A00;
    pub const ldrb: u16 = 0x5C00;
    pub const ldrsh: u16 = 0x5E00;
};

pub const group: op.Group = .{ .name = "ldst_reg", .decode = decode };

/// What one encoding moves and where.
pub const Access = struct {
    rt: u3,
    address: u32,
    /// 1, 2 or 4 bytes.
    size: u3,
    signed: bool,
};

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 2) return null;
    return switch (instr.hw1 & encodings.mask) {
        encodings.str, encodings.strh, encodings.strb => store,
        encodings.ldr, encodings.ldrh, encodings.ldrb, encodings.ldrsb, encodings.ldrsh => load,
        else => null,
    };
}

/// The access an encoding this group claims makes on `cpu`'s registers.
pub fn access(cpu: *const Cpu, hw1: u16) Access {
    const kind = hw1 & encodings.mask;
    const size: u3 = switch (kind) {
        encodings.str, encodings.ldr => 4,
        encodings.strh, encodings.ldrh, encodings.ldrsh => 2,
        else => 1,
    };
    const rm: u4 = @intCast((hw1 >> 6) & 7);
    const rn: u4 = @intCast((hw1 >> 3) & 7);
    return .{
        .rt = @intCast(hw1 & 7),
        .address = cpu.regs.get(rn) +% cpu.regs.get(rm),
        .size = size,
        .signed = kind == encodings.ldrsb or kind == encodings.ldrsh,
    };
}

fn store(cpu: *Cpu, instr: Instr) op.Error!void {
    const a = access(cpu, instr.hw1);
    try alignment.memU(cpu.bus, a.address, a.size);
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, cpu.regs.get(a.rt), .little);
    try cpu.bus.write(a.address, bytes[0..a.size]);
}

fn load(cpu: *Cpu, instr: Instr) op.Error!void {
    const a = access(cpu, instr.hw1);
    try alignment.memU(cpu.bus, a.address, a.size);
    var bytes = @as([4]u8, @splat(0));
    try cpu.bus.read(a.address, bytes[0..a.size]);
    var value = std.mem.readInt(u32, &bytes, .little);
    if (a.signed) {
        const top: u5 = @intCast(@as(u6, a.size) * 8 - 1);
        if ((value >> top) & 1 != 0) value |= ~@as(u32, 0) << top;
    }
    cpu.regs.set(a.rt, value);
}
