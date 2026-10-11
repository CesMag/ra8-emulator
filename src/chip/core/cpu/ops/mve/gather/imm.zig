//! MVE vector-base gather loads and scatter stores (RA8EMU-25):
//! VLDRW.U32, VLDRD.U64, VSTRW.32 and VSTRD.64 [Qm, #imm]{!}. Each Qm
//! word (or the even word of each doubleword pair) is a base address that
//! gather.vectorAddress moves by imm7; a doubleword's odd beat sits four
//! bytes higher. Active beats go through the bus lowest first, inactive
//! ones load as zero and touch no memory. With writeback every address,
//! predicated or not, replaces its Qm element, then VPT advances.
//!
//!   hw1 1111 1101 A D W L Qm[2:0] 0    hw2 Qd 1 111 D M imm7
//!
//! hw2 bit 8 picks doublewords. Q8+ (D or M) and a load whose Qd is Qm
//! stay unclaimed.
const std = @import("std");
const op = @import("../../../op.zig");
const Cpu = @import("../../../cpu.zig").Cpu;
const Instr = @import("../../../instr.zig").Instr;
const alignment = @import("../../../alignment.zig");
const mve = @import("../../../mve/all.zig");
const mve_beats = @import("../beats.zig");
const gather = mve.gather;

pub const group: op.Group = .{ .name = "mve_gather_imm", .decode = decode, .oracle = false };

pub const encodings = struct {
    pub const hw1_mask: u16 = 0xFF01;
    pub const hw1: u16 = 0xFD00;
    pub const hw2_mask: u16 = 0x1E00;
    pub const hw2: u16 = 0x1E00;
};

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4) return null;
    if (instr.hw1 & encodings.hw1_mask != encodings.hw1) return null;
    if (instr.hw2 & encodings.hw2_mask != encodings.hw2) return null;
    if (instr.hw1 >> 6 & 1 == 1 or instr.hw2 >> 7 & 1 == 1) return null;
    const load = instr.hw1 >> 4 & 1 == 1;
    if (load and instr.hw2 >> 13 & 7 == instr.hw1 >> 1 & 7) return null;
    return &run;
}

fn run(cpu: *Cpu, instr: Instr) op.Error!void {
    const qm: u3 = @intCast(instr.hw1 >> 1 & 7);
    const qd: u3 = @intCast(instr.hw2 >> 13 & 7);
    const double = instr.hw2 >> 8 & 1 == 1;
    const load = instr.hw1 >> 4 & 1 == 1;
    const bases = mve.qreg.read(&cpu.fp.bank, qm);
    const value = mve.qreg.read(&cpu.fp.bank, qd);
    const mask = mve_beats.mask(cpu);
    var out: u128 = 0;
    var moved = bases;
    for (0..4) |k| {
        const e: u8 = @intCast(k);
        const slot: u8 = if (double) e & 0b10 else e;
        const at = gather.vectorAddress(.{
            .element = mve.qreg.elem(bases, .word, slot),
            .imm7 = @truncate(instr.hw2),
            .add = instr.hw1 >> 7 & 1 == 1,
            .double = double,
        });
        if (!double or e & 1 == 1) moved = mve.qreg.setElem(moved, .word, slot, at);
        const beat = if (double and e & 1 == 1) at +% 4 else at;
        if (!mve.predicate.active(mask, .word, e)) continue;
        try alignment.memA(beat, 4);
        var buf: [4]u8 = undefined;
        if (load) {
            try cpu.bus.read(beat, &buf);
            out = mve.qreg.setElem(out, .word, e, std.mem.readInt(u32, &buf, .little));
        } else {
            std.mem.writeInt(u32, &buf, mve.qreg.elem(value, .word, e), .little);
            try cpu.bus.write(beat, &buf);
        }
    }
    if (load) mve_beats.keep(cpu, qd, out);
    if (instr.hw1 >> 5 & 1 == 1) mve_beats.keep(cpu, qm, moved);
    mve_beats.finish(cpu);
}
