//! Load and store with an immediate offset, 32-bit. The imm12 forms add a
//! positive offset with no writeback (STR T3, STRB T2, STRH T2, LDR T3,
//! LDRB T2, LDRH T2, LDRSB T1, LDRSH T1); the imm8 forms take P/U/W for the
//! offset, pre-indexed and post-indexed addressing (STR T4, STRB T3,
//! STRH T3, LDR T4, LDRB T3, LDRH T3, LDRSB T2, LDRSH T2).
//!
//! The imm8 encoding with P=1 U=1 W=0 is the unprivileged family LDRT,
//! LDRBT, LDRHT, LDRSBT, LDRSHT, STRT, STRBT and STRHT (RA8EMU-133): a
//! positive offset, no writeback, and `Form.unprivileged` set: the MPU
//! checks the access as unprivileged from any mode (RA8EMU-370).
//!
//! Left unclaimed for their own slices or as UNPREDICTABLE: Rn = PC (the
//! literal forms), the register-offset forms, byte and halfword loads to the
//! PC (PLD/PLI), a store of the PC, SP as a byte or halfword Rt, SP or PC as
//! an unprivileged Rt, and writeback with Rn = Rt.
//! An unaligned word or halfword goes through as bytes, the behaviour with
//! CCR.UNALIGN_TRP clear; with it set the core stops (RA8EMU-85).
const std = @import("std");
const op = @import("../../op.zig");
const alignment = @import("../../alignment.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;
const bti = @import("../../bti.zig");

pub const encodings = struct {
    /// hw1[15:9] = 0b1111100 for the whole single-register load/store space.
    pub const mask: u16 = 0xFE00;
    pub const space: u16 = 0xF800;
    pub const signed: u16 = 1 << 8;
    pub const imm12: u16 = 1 << 7;
    pub const load: u16 = 1 << 4;
    /// hw2[11] set marks an imm8 form; clear is the register-offset space.
    pub const imm8: u16 = 1 << 11;
};

pub const group: op.Group = .{ .name = "ldst_wide", .decode = decode };

/// What one encoding moves and how it addresses memory.
pub const Form = struct {
    rt: u4,
    rn: u4,
    /// 1, 2 or 4 bytes.
    size: u3,
    load: bool,
    /// Sign-extend a byte or halfword load.
    signed: bool,
    offset: u32,
    add: bool,
    /// Address with the offset applied (P); false is post-indexed.
    index: bool,
    writeback: bool,
    /// LDRT/STRT family: the access is checked as unprivileged.
    unprivileged: bool = false,
};

/// The form of an encoding this group claims, or null.
pub fn form(instr: Instr) ?Form {
    if (instr.size != 4 or instr.hw1 & encodings.mask != encodings.space) return null;
    const hw1 = instr.hw1;
    const size: u3 = switch ((hw1 >> 5) & 3) {
        0 => 1,
        1 => 2,
        2 => 4,
        else => return null,
    };
    var f: Form = .{
        .rt = @intCast(instr.hw2 >> 12),
        .rn = @intCast(hw1 & 0xF),
        .size = size,
        .load = hw1 & encodings.load != 0,
        .signed = hw1 & encodings.signed != 0,
        .offset = instr.hw2 & 0xFFF,
        .add = true,
        .index = true,
        .writeback = false,
    };
    if (hw1 & encodings.imm12 == 0 and !addressing(&f, instr.hw2)) return null;
    return if (allowed(f)) f else null;
}

/// Fill in the imm8 P/U/W addressing; false when it is not one this group
/// runs (the register-offset space, or P=0 W=0). P=1 U=1 W=0 is LDRT/STRT.
fn addressing(f: *Form, hw2: u16) bool {
    if (hw2 & encodings.imm8 == 0) return false;
    const p = hw2 & (1 << 10) != 0;
    const u = hw2 & (1 << 9) != 0;
    const w = hw2 & (1 << 8) != 0;
    if (!p and !w) return false;
    f.offset = hw2 & 0xFF;
    f.add = u;
    f.index = p;
    f.writeback = w;
    f.unprivileged = p and u and !w;
    return true;
}

/// The register and opcode choices the Arm ARM leaves defined.
fn allowed(f: Form) bool {
    if (f.rn == 15) return false;
    if (f.unprivileged and (f.rt == 13 or f.rt == 15)) return false;
    if (f.signed and (!f.load or f.size == 4)) return false;
    const word_load = f.load and f.size == 4;
    if (f.rt == 15 and !word_load) return false;
    if (f.rt == 13 and f.size != 4) return false;
    if (f.writeback and f.rn == f.rt) return false;
    return true;
}

fn decode(instr: Instr) ?op.Exec {
    return if (form(instr) != null) run else null;
}

fn run(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = form(instr).?;
    const base = cpu.regs.get(f.rn);
    const offset_address = if (f.add) base +% f.offset else base -% f.offset;
    const address = if (f.index) offset_address else base;
    const kept: ?bool = if (!f.unprivileged) null else if (cpu.mpu) |m| m.lower() else null;
    defer if (kept) |was| {
        cpu.mpu.?.privileged = was;
    };
    try alignment.memU(cpu.bus, address, f.size);
    if (!f.load) {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, cpu.regs.get(f.rt), .little);
        try cpu.bus.write(address, bytes[0..f.size]);
        if (f.writeback) cpu.regs.set(f.rn, offset_address);
        return;
    }
    const value = try loadValue(cpu, address, f);
    if (f.writeback) cpu.regs.set(f.rn, offset_address);
    if (f.rt == 15) {
        cpu.regs.bxWritePc(value);
        if ((f.rn != 13 or !f.writeback) and cpu.regs.exc_return == null) bti.setForAddress(&cpu.regs, cpu.profile.v8_1m);
    } else cpu.regs.set(f.rt, value);
}

fn loadValue(cpu: *Cpu, address: u32, f: Form) op.Error!u32 {
    var bytes = @as([4]u8, @splat(0));
    try cpu.bus.read(address, bytes[0..f.size]);
    const raw = std.mem.readInt(u32, &bytes, .little);
    if (!f.signed) return raw;
    return switch (f.size) {
        1 => @bitCast(@as(i32, @as(i8, @bitCast(@as(u8, @truncate(raw)))))),
        else => @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(raw)))))),
    };
}
