//! MVE gather loads and scatter stores with vector offsets (RA8EMU-25):
//! VLDRB/VLDRH/VLDRW [Rn, Qm{, uxtw #n}] and VSTRB/VSTRH/VSTRW [Rn, Qm].
//! gather.zig works out each element's address; contiguous.element
//! widens or narrows it. Active elements go through the bus lowest first,
//! inactive ones load as zero and touch no memory, then VPT advances.
//!
//!   hw1 111U 1100 1D0L Rn      hw2 Qd 0 111 size msize[1] M msize[0] Qm os
//!
//! U clear makes a load signed and must be clear for a store. Q8+ (D or
//! M), Rn = PC, a load whose Qd is Qm, memory or element size 11 (the
//! 64-bit VLDRD/VSTRD, in mve_gather64.zig) and the size combinations
//! gather.valid rejects stay unclaimed.
const std = @import("std");
const op = @import("../../../op.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;
const alignment = @import("../../../alignment.zig");
const mve = @import("../../../mve/all.zig");
const mve_beats = @import("../beats.zig");
pub const imm = @import("imm.zig");
const gather = mve.gather;
const contiguous = mve.contiguous;
const Size = mve.qreg.Size;

pub const group: op.Group = .{ .name = "mve_gather", .decode = decode, .oracle = false };

pub const encodings = struct {
    pub const hw1_mask: u16 = 0xEFA0;
    pub const hw1: u16 = 0xEC80;
    pub const hw2_mask: u16 = 0x1E00;
    pub const hw2: u16 = 0x0E00;
};

fn sizeOf(field: u16) ?Size {
    return switch (field) {
        0 => .byte,
        1 => .half,
        2 => .word,
        else => null,
    };
}

/// The access an encoding names, or null when it is not a defined one.
pub fn formOf(instr: Instr) ?gather.Form {
    const store = instr.hw1 >> 4 & 1 == 0;
    const f: gather.Form = .{
        .msize = sizeOf((instr.hw2 >> 5 & 2) | (instr.hw2 >> 4 & 1)) orelse return null,
        .esize = sizeOf(instr.hw2 >> 7 & 3) orelse return null,
        .signed = !store and instr.hw1 >> 12 & 1 == 0,
        .store = store,
        .os = instr.hw2 & 1 == 1,
    };
    if (store and instr.hw1 >> 12 & 1 == 1) return null;
    return if (gather.valid(f)) f else null;
}

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4) return null;
    if (instr.hw1 & encodings.hw1_mask != encodings.hw1) return null;
    if (instr.hw2 & encodings.hw2_mask != encodings.hw2) return null;
    if (instr.hw1 >> 6 & 1 == 1 or instr.hw2 >> 5 & 1 == 1) return null;
    if (instr.hw1 & 0xF == 15) return null;
    const f = formOf(instr) orelse return null;
    if (!f.store and instr.hw2 >> 13 & 7 == instr.hw2 >> 1 & 7) return null;
    return &run;
}

fn run(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = formOf(instr).?;
    const base = cpu.regs.get(@intCast(instr.hw1 & 0xF));
    const qd: u3 = @intCast(instr.hw2 >> 13 & 7);
    const offsets = mve.qreg.read(&cpu.fp.bank, @intCast(instr.hw2 >> 1 & 7));
    const mask = mve_beats.mask(cpu);
    const value = mve.qreg.read(&cpu.fp.bank, qd);
    var out: u128 = 0;
    for (0..mve.qreg.lanes(f.esize)) |k| {
        const e: u8 = @intCast(k);
        if (!mve.predicate.active(mask, f.esize, e)) continue;
        const offset = mve.qreg.elem(offsets, f.esize, e);
        const at = gather.address(.{ .base = base, .offset = offset, .msize = f.msize, .os = f.os });
        const len = contiguous.bytes(f.msize);
        try alignment.memA(at, len);
        var buf: [4]u8 = .{ 0, 0, 0, 0 };
        if (f.store) {
            const raw = mve.qreg.elem(value, f.esize, e);
            std.mem.writeInt(u32, &buf, contiguous.element(.{ .value = raw, .msize = f.msize, .signed = false, .store = true }), .little);
            try cpu.bus.write(at, buf[0..len]);
        } else {
            try cpu.bus.read(at, buf[0..len]);
            const raw = std.mem.readInt(u32, &buf, .little);
            out = mve.qreg.setElem(out, f.esize, e, contiguous.element(.{ .value = raw, .msize = f.msize, .signed = f.signed, .store = false }));
        }
    }
    if (!f.store) mve_beats.keep(cpu, qd, out);
    mve_beats.finish(cpu);
}
