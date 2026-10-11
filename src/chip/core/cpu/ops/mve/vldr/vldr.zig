//! MVE contiguous VLDR/VSTR with elements as wide as memory (RA8EMU-25):
//! VLDRB.8, VLDRH.16, VLDRW.32 and their stores. contiguous.zig plans the
//! addresses; this file moves the active elements through the bus, lowest
//! first, then advances VPT and writes Rn back once every access is done.
//!
//!   hw1 1110 110 P A D W L Rn    hw2 Qd 1 111 size imm7
//!
//! A adds the offset, L loads. P and W both clear is another encoding,
//! and D set (Q8 and up), size 11, a PC base, or an SP base with writeback
//! stay unclaimed (CONSTRAINED UNPREDICTABLE, undefined as QEMU does).
//! Active elements are MemA accesses and fault before reaching the bus.
const std = @import("std");
const op = @import("../../../op.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;
const alignment = @import("../../../alignment.zig");
const mve = @import("../../../mve/all.zig");
const mve_beats = @import("../beats.zig");
pub const wide = @import("wide.zig");
const contiguous = mve.contiguous;
const Size = mve.qreg.Size;

pub const group: op.Group = .{ .name = "mve_vldr", .decode = decode, .oracle = false };

pub const encodings = struct {
    pub const hw1_mask: u16 = 0xFE40;
    pub const hw1: u16 = 0xEC00;
    pub const hw2_mask: u16 = 0x1E00;
    pub const hw2: u16 = 0x1E00;
};

pub fn sizeOf(instr: Instr) ?Size {
    return switch (instr.hw2 >> 7 & 3) {
        0 => .byte,
        1 => .half,
        2 => .word,
        else => null,
    };
}

/// The address plan for `base`, Rn's value.
pub fn form(instr: Instr, base: u32) ?contiguous.Form {
    return .{
        .base = base,
        .imm7 = @truncate(instr.hw2),
        .size = sizeOf(instr) orelse return null,
        .add = instr.hw1 >> 7 & 1 == 1,
        .pre = instr.hw1 >> 8 & 1 == 1,
        .wback = instr.hw1 >> 5 & 1 == 1,
    };
}

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4) return null;
    if (instr.hw1 & encodings.hw1_mask != encodings.hw1) return null;
    if (instr.hw2 & encodings.hw2_mask != encodings.hw2) return null;
    const f = form(instr, 0) orelse return null;
    const rn = instr.hw1 & 0xF;
    if (!f.pre and !f.wback) return null;
    if (rn == 15 or (rn == 13 and f.wback)) return null;
    return &run;
}

fn run(cpu: *Cpu, instr: Instr) op.Error!void {
    const rn: u4 = @intCast(instr.hw1 & 0xF);
    const f = form(instr, cpu.regs.get(rn)).?;
    const p = contiguous.plan(f);
    const qd: u3 = @intCast(instr.hw2 >> 13);
    const mask = mve_beats.mask(cpu);
    if (instr.hw1 >> 4 & 1 == 1) {
        mve_beats.keep(cpu, qd, try load(cpu, p.start, f.size, mask));
    } else {
        try store(cpu, p.start, f.size, mask, mve.qreg.read(&cpu.fp.bank, qd));
    }
    mve_beats.finish(cpu);
    if (p.wback) |value| cpu.regs.set(rn, value);
}

fn load(cpu: *Cpu, start: u32, size: Size, mask: u16) op.Error!u128 {
    var out: u128 = 0;
    for (0..mve.qreg.lanes(size)) |k| {
        const e: u8 = @intCast(k);
        if (!mve.predicate.active(mask, size, e)) continue;
        try alignment.memA(contiguous.address(start, size, e), contiguous.bytes(size));
        var buf: [4]u8 = .{ 0, 0, 0, 0 };
        try cpu.bus.read(contiguous.address(start, size, e), buf[0..contiguous.bytes(size)]);
        out = mve.qreg.setElem(out, size, e, std.mem.readInt(u32, &buf, .little));
    }
    return out;
}

fn store(cpu: *Cpu, start: u32, size: Size, mask: u16, value: u128) op.Error!void {
    for (0..mve.qreg.lanes(size)) |k| {
        const e: u8 = @intCast(k);
        if (!mve.predicate.active(mask, size, e)) continue;
        try alignment.memA(contiguous.address(start, size, e), contiguous.bytes(size));
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, mve.qreg.elem(value, size, e), .little);
        try cpu.bus.write(contiguous.address(start, size, e), buf[0..contiguous.bytes(size)]);
    }
}
