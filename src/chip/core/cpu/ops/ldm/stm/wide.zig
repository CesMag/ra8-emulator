//! Load and store multiple, 32-bit: STM (IA) T2, LDM (IA) T2, STMDB T1 and
//! LDMDB T1, with PUSH.W (STMDB SP!) and POP.W (LDMIA SP!) as their aliases.
//!
//! Registers go lowest-numbered at the lowest address. A load of the PC
//! writes it with BXWritePC, after the other registers. Left unclaimed as
//! UNPREDICTABLE: Rn = PC, fewer than two registers, SP in the list, the PC
//! in a store list, P and M both set on a load, and writeback with Rn in the
//! list. Every access goes through the bus.
const std = @import("std");
const op = @import("../../../op.zig");
const alignment = @import("../../../alignment.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;
const bti = @import("../../../bti.zig");

pub const encodings = struct {
    /// hw1 with W and Rn masked out.
    pub const mask: u16 = 0xFFD0;
    pub const stm_ia: u16 = 0xE880;
    pub const ldm_ia: u16 = 0xE890;
    pub const stm_db: u16 = 0xE900;
    pub const ldm_db: u16 = 0xE910;
    pub const wback: u16 = 1 << 5;
};

pub const group: op.Group = .{ .name = "ldm_stm_wide", .decode = decode };

pub const Form = struct {
    rn: u4,
    list: u16,
    load: bool,
    /// Decrement before rather than increment after.
    before: bool,
    wback: bool,

    pub fn of(instr: Instr) ?Form {
        if (instr.size != 4) return null;
        const kind = instr.hw1 & encodings.mask;
        const load = kind == encodings.ldm_ia or kind == encodings.ldm_db;
        const before = kind == encodings.stm_db or kind == encodings.ldm_db;
        if (!load and !before and kind != encodings.stm_ia) return null;
        return .{
            .rn = @intCast(instr.hw1 & 0xF),
            .list = instr.hw2,
            .load = load,
            .before = before,
            .wback = instr.hw1 & encodings.wback != 0,
        };
    }

    /// Whether the register choices are architecturally defined.
    pub fn allowed(self: Form) bool {
        const sp: u16 = 1 << 13;
        const pc: u16 = 1 << 15;
        const lr: u16 = 1 << 14;
        if (self.rn == 15 or @popCount(self.list) < 2 or self.list & sp != 0) return false;
        if (!self.load and self.list & pc != 0) return false;
        if (self.load and self.list & (pc | lr) == pc | lr) return false;
        const rn_bit = @as(u16, 1) << self.rn;
        return !(self.wback and self.list & rn_bit != 0);
    }

    fn bytes(self: Form) u32 {
        return @as(u32, @popCount(self.list)) * 4;
    }
};

fn decode(instr: Instr) ?op.Exec {
    const form = Form.of(instr) orelse return null;
    if (!form.allowed()) return null;
    return if (form.load) ldm else stm;
}

/// The lowest address touched and the base after writeback.
fn span(cpu: *const Cpu, form: Form) struct { start: u32, after: u32 } {
    const base = cpu.regs.get(form.rn);
    if (form.before) {
        const start = base -% form.bytes();
        return .{ .start = start, .after = start };
    }
    return .{ .start = base, .after = base +% form.bytes() };
}

fn stm(cpu: *Cpu, instr: Instr) op.Error!void {
    const form = Form.of(instr).?;
    const at = span(cpu, form);
    try alignment.memA(at.start, 4);
    var address = at.start;
    for (0..16) |i| {
        if (form.list & (@as(u16, 1) << @intCast(i)) == 0) continue;
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, cpu.regs.get(@intCast(i)), .little);
        try cpu.bus.write(address, &bytes);
        address +%= 4;
    }
    if (form.wback) cpu.regs.set(form.rn, at.after);
}

fn ldm(cpu: *Cpu, instr: Instr) op.Error!void {
    const form = Form.of(instr).?;
    const at = span(cpu, form);
    try alignment.memA(at.start, 4);
    var values: [16]u32 = undefined;
    var address = at.start;
    for (0..16) |i| {
        if (form.list & (@as(u16, 1) << @intCast(i)) == 0) continue;
        values[i] = try cpu.bus.readWord(address);
        address +%= 4;
    }
    if (form.wback) cpu.regs.set(form.rn, at.after);
    for (0..15) |i| {
        if (form.list & (@as(u16, 1) << @intCast(i)) != 0) cpu.regs.set(@intCast(i), values[i]);
    }
    if (form.list & (1 << 15) != 0) {
        cpu.regs.bxWritePc(values[15]);
        if (form.rn != 13 and cpu.regs.exc_return == null) bti.setForAddress(&cpu.regs, cpu.profile.v8_1m);
    }
}
