//! MVE widening loads and narrowing stores (RA8EMU-25): VLDRB.S16/U16/
//! S32/U32, VLDRH.S32/U32, VSTRB.16/32 and VSTRH.32. contiguous.zig plans
//! the addresses by the memory size and converts each element; this file
//! moves the active ones through the bus, lowest first, then advances VPT
//! and writes Rn back once every access is done.
//!
//!   hw1 111U 110P AD0W LHRn    hw2 Qd 0 111 size imm7
//!
//! H picks halfwords in memory (else bytes) and size the register element
//! (01 half, 10 word). Rn and Qd are three bits, so neither PC, SP nor Q8+
//! can be named. H with a halfword element, sizes 00 and 11, P and W both
//! clear (other encodings) and a store with U set stay unclaimed.
//! Active elements are MemA accesses and fault before reaching the bus.
const std = @import("std");
const op = @import("../../../op.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;
const alignment = @import("../../../alignment.zig");
const mve = @import("../../../mve/all.zig");
const mve_beats = @import("../beats.zig");
const contiguous = mve.contiguous;
const Size = mve.qreg.Size;

pub const group: op.Group = .{ .name = "mve_vldr_wide", .decode = decode, .oracle = false };

pub const encodings = struct {
    pub const hw1_mask: u16 = 0xEE40;
    pub const hw1: u16 = 0xEC00;
    pub const hw2_mask: u16 = 0x1E00;
    pub const hw2: u16 = 0x0E00;
};

pub const Sizes = struct { memory: Size, element: Size };

/// The memory and register element sizes, or null for other encodings.
pub fn sizesOf(instr: Instr) ?Sizes {
    const half = instr.hw1 >> 3 & 1 == 1;
    return switch (instr.hw2 >> 7 & 3) {
        1 => if (half) null else .{ .memory = .byte, .element = .half },
        2 => .{ .memory = if (half) .half else .byte, .element = .word },
        else => null,
    };
}

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4) return null;
    if (instr.hw1 & encodings.hw1_mask != encodings.hw1) return null;
    if (instr.hw2 & encodings.hw2_mask != encodings.hw2) return null;
    _ = sizesOf(instr) orelse return null;
    const pre = instr.hw1 >> 8 & 1 == 1;
    const wback = instr.hw1 >> 5 & 1 == 1;
    const is_load = instr.hw1 >> 4 & 1 == 1;
    const unsigned = instr.hw1 >> 12 & 1 == 1;
    if (!pre and !wback) return null;
    if (!is_load and unsigned) return null;
    return &run;
}

fn run(cpu: *Cpu, instr: Instr) op.Error!void {
    const rn: u4 = @intCast(instr.hw1 & 7);
    const s = sizesOf(instr).?;
    const p = contiguous.plan(.{
        .base = cpu.regs.get(rn),
        .imm7 = @truncate(instr.hw2),
        .size = s.memory,
        .add = instr.hw1 >> 7 & 1 == 1,
        .pre = instr.hw1 >> 8 & 1 == 1,
        .wback = instr.hw1 >> 5 & 1 == 1,
    });
    const qd: u3 = @intCast(instr.hw2 >> 13 & 7);
    const mask = mve_beats.mask(cpu);
    if (instr.hw1 >> 4 & 1 == 1) {
        const signed = instr.hw1 >> 12 & 1 == 0;
        mve_beats.keep(cpu, qd, try load(cpu, p.start, s, mask, signed));
    } else {
        try store(cpu, p.start, s, mask, mve.qreg.read(&cpu.fp.bank, qd));
    }
    mve_beats.finish(cpu);
    if (p.wback) |value| cpu.regs.set(rn, value);
}

fn load(cpu: *Cpu, start: u32, s: Sizes, mask: u16, signed: bool) op.Error!u128 {
    var out: u128 = 0;
    for (0..mve.qreg.lanes(s.element)) |k| {
        const e: u8 = @intCast(k);
        if (!mve.predicate.active(mask, s.element, e)) continue;
        try alignment.memA(contiguous.address(start, s.memory, e), contiguous.bytes(s.memory));
        var buf: [4]u8 = .{ 0, 0, 0, 0 };
        try cpu.bus.read(contiguous.address(start, s.memory, e), buf[0..contiguous.bytes(s.memory)]);
        const raw = std.mem.readInt(u32, &buf, .little);
        const value = contiguous.element(.{ .value = raw, .msize = s.memory, .signed = signed, .store = false });
        out = mve.qreg.setElem(out, s.element, e, value);
    }
    return out;
}

fn store(cpu: *Cpu, start: u32, s: Sizes, mask: u16, value: u128) op.Error!void {
    for (0..mve.qreg.lanes(s.element)) |k| {
        const e: u8 = @intCast(k);
        if (!mve.predicate.active(mask, s.element, e)) continue;
        try alignment.memA(contiguous.address(start, s.memory, e), contiguous.bytes(s.memory));
        const raw = mve.qreg.elem(value, s.element, e);
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, contiguous.element(.{ .value = raw, .msize = s.memory, .signed = false, .store = true }), .little);
        try cpu.bus.write(contiguous.address(start, s.memory, e), buf[0..contiguous.bytes(s.memory)]);
    }
}
