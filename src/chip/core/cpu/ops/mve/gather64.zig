//! MVE 64-bit gather loads and scatter stores with vector offsets
//! (RA8EMU-25): VLDRD.U64 and VSTRD.64 [Rn, Qm{, uxtw #3}]. Each
//! doubleword moves as two word beats, each under its own beat's
//! predicate; the even word of its Qm pair holds the offset for both.
//! Inactive beats load as zero and touch no memory, then VPT advances.
//!
//!   hw1 111U 1100 1D0L Rn      hw2 Qd 0 111 11 1 M 1 Qm os
//!
//! A load needs U set (there is no signed 64-bit form) and a store U
//! clear. Q8+ (D or M), Rn = PC and a load whose Qd is Qm stay unclaimed.
//! The narrower element sizes live in mve_gather.zig.
const std = @import("std");
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;
const alignment = @import("../../alignment.zig");
const mve = @import("../../mve/all.zig");
const mve_beats = @import("beats.zig");
const gather = mve.gather;

pub const group: op.Group = .{ .name = "mve_gather64", .decode = decode, .oracle = false };

pub const encodings = struct {
    pub const hw1_mask: u16 = 0xEFE0;
    pub const hw1: u16 = 0xEC80;
    pub const hw2_mask: u16 = 0x1FF0;
    pub const hw2: u16 = 0x0FD0;
};

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4) return null;
    if (instr.hw1 & encodings.hw1_mask != encodings.hw1) return null;
    if (instr.hw2 & encodings.hw2_mask != encodings.hw2) return null;
    if (instr.hw1 & 0xF == 15) return null;
    const load = instr.hw1 >> 4 & 1 == 1;
    const unsigned = instr.hw1 >> 12 & 1 == 1;
    if (load != unsigned) return null;
    if (load and instr.hw2 >> 13 & 7 == instr.hw2 >> 1 & 7) return null;
    return &run;
}

fn run(cpu: *Cpu, instr: Instr) op.Error!void {
    const base = cpu.regs.get(@intCast(instr.hw1 & 0xF));
    const qd: u3 = @intCast(instr.hw2 >> 13 & 7);
    const offsets = mve.qreg.read(&cpu.fp.bank, @intCast(instr.hw2 >> 1 & 7));
    const load = instr.hw1 >> 4 & 1 == 1;
    const mask = mve_beats.mask(cpu);
    const value = mve.qreg.read(&cpu.fp.bank, qd);
    var out: u128 = 0;
    for (0..4) |k| {
        const e: u8 = @intCast(k);
        if (!mve.predicate.active(mask, .word, e)) continue;
        const at = gather.beatAddress(.{
            .base = base,
            .offset = mve.qreg.elem(offsets, .word, e & 0b10),
            .os = instr.hw2 & 1 == 1,
            .odd = e & 1 == 1,
        });
        try alignment.memA(at, 4);
        var buf: [4]u8 = undefined;
        if (load) {
            try cpu.bus.read(at, &buf);
            out = mve.qreg.setElem(out, .word, e, std.mem.readInt(u32, &buf, .little));
        } else {
            std.mem.writeInt(u32, &buf, mve.qreg.elem(value, .word, e), .little);
            try cpu.bus.write(at, &buf);
        }
    }
    if (load) mve_beats.keep(cpu, qd, out);
    mve_beats.finish(cpu);
}
