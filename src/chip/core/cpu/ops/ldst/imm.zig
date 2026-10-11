//! Load and store with an immediate offset, 16-bit: STR/LDR, STRB/LDRB and
//! STRH/LDRH [Rn, #imm5] (T1), and STR/LDR [SP, #imm8] (T2). No writeback,
//! and byte and halfword loads zero-extend. An unaligned word or halfword
//! goes through as bytes, the behaviour with CCR.UNALIGN_TRP clear; with it
//! set the core stops (RA8EMU-85).
const std = @import("std");
const op = @import("../../op.zig");
const alignment = @import("../../alignment.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;

pub const encodings = struct {
    pub const mask: u16 = 0xF800;
    pub const str_imm5: u16 = 0x6000;
    pub const ldr_imm5: u16 = 0x6800;
    pub const strb_imm5: u16 = 0x7000;
    pub const ldrb_imm5: u16 = 0x7800;
    pub const strh_imm5: u16 = 0x8000;
    pub const ldrh_imm5: u16 = 0x8800;
    pub const str_sp: u16 = 0x9000;
    pub const ldr_sp: u16 = 0x9800;
};

pub const group: op.Group = .{ .name = "ldst_imm", .decode = decode };

/// What one encoding moves and where.
pub const Access = struct {
    rt: u4,
    address: u32,
    /// 1, 2 or 4 bytes.
    size: u3,
    load: bool,
};

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 2) return null;
    return switch (instr.hw1 & encodings.mask) {
        encodings.str_imm5, encodings.strb_imm5, encodings.strh_imm5, encodings.str_sp => store,
        encodings.ldr_imm5, encodings.ldrb_imm5, encodings.ldrh_imm5, encodings.ldr_sp => load,
        else => null,
    };
}

/// The access an encoding this group claims makes on `cpu`'s registers.
pub fn access(cpu: *const Cpu, hw1: u16) Access {
    const kind = hw1 & encodings.mask;
    const is_load = kind & 0x0800 != 0;
    if (kind & ~@as(u16, 0x0800) == encodings.str_sp) {
        const offset = @as(u32, hw1 & 0xFF) << 2;
        return .{ .rt = @intCast((hw1 >> 8) & 7), .address = cpu.regs.sp() +% offset, .size = 4, .load = is_load };
    }
    const size: u3 = switch (kind & ~@as(u16, 0x0800)) {
        encodings.str_imm5 => 4,
        encodings.strb_imm5 => 1,
        else => 2,
    };
    const offset = @as(u32, (hw1 >> 6) & 0x1F) * size;
    const rn: u4 = @intCast((hw1 >> 3) & 7);
    return .{ .rt = @intCast(hw1 & 7), .address = cpu.regs.get(rn) +% offset, .size = size, .load = is_load };
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
    cpu.regs.set(a.rt, std.mem.readInt(u32, &bytes, .little));
}
