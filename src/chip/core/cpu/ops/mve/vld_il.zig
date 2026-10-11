//! MVE interleaving loads and stores (RA8EMU-25): VLD20/VLD21,
//! VLD40..VLD43, VST20/VST21 and VST40..VST43 with {Qd..Qd+n-1}, [Rn]{!}.
//! interleave.zig gives each beat's word offset and the register and
//! element of every memory element in it. The four words move lowest
//! beat first; W adds 32 (VLD2/VST2) or 64 (VLD4/VST4) to Rn after.
//! These are not predicated and leave VPT alone, as QEMU models them;
//! beats EPSR.ECI marks done are skipped and ECI moves on after.
//!
//!   hw1 1111 1100 1 D W L Rn      hw2 Qd 1 111 size pat 0000 four
//!
//! Q8+ (D set), a register list past Q7, size 11, a pattern past the
//! list, Rn = PC and SP with writeback stay unclaimed.
const std = @import("std");
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;
const alignment = @import("../../alignment.zig");
const mve = @import("../../mve/all.zig");
const mve_beats = @import("beats.zig");
const interleave = mve.interleave;
const Size = mve.qreg.Size;

pub const group: op.Group = .{ .name = "mve_vld_il", .decode = decode, .oracle = false };

pub const encodings = struct {
    pub const hw1_mask: u16 = 0xFFC0;
    pub const hw1: u16 = 0xFC80;
    pub const hw2_mask: u16 = 0x1E1E;
    pub const hw2: u16 = 0x1E00;
};

fn regsOf(instr: Instr) u3 {
    return if (instr.hw2 & 1 == 1) 4 else 2;
}

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4) return null;
    if (instr.hw1 & encodings.hw1_mask != encodings.hw1) return null;
    if (instr.hw2 & encodings.hw2_mask != encodings.hw2) return null;
    const regs = regsOf(instr);
    const rn = instr.hw1 & 0xF;
    if (rn == 15 or (rn == 13 and instr.hw1 >> 5 & 1 == 1)) return null;
    if (instr.hw2 >> 7 & 3 == 3) return null;
    if (instr.hw2 >> 5 & 3 >= regs) return null;
    if ((instr.hw2 >> 13) + regs > 8) return null;
    return &run;
}

fn run(cpu: *Cpu, instr: Instr) op.Error!void {
    const regs = regsOf(instr);
    const rn: u4 = @intCast(instr.hw1 & 0xF);
    const base = cpu.regs.get(rn);
    const qd: u3 = @intCast(instr.hw2 >> 13);
    const size: Size = @fromBackingInt(@intCast(instr.hw2 >> 7 & 3));
    const load = instr.hw1 >> 4 & 1 == 1;
    var q: [4]u128 = undefined;
    for (0..regs) |r| q[r] = mve.qreg.read(&cpu.fp.bank, @intCast(qd + r));
    const pending = mve_beats.pending(cpu);
    for (0..4) |b| {
        if (pending >> @intCast(b * 4) & 1 == 0) continue;
        const off = interleave.beatOffset(.{ .regs = regs, .pat = @intCast(instr.hw2 >> 5 & 3), .beat = @intCast(b) });
        try alignment.memA(base +% off, @intCast(mve.qreg.bits(size) / 8));
        var buf: [4]u8 = undefined;
        if (load) {
            try cpu.bus.read(base +% off, &buf);
            scatter(&q, regs, size, off, std.mem.readInt(u32, &buf, .little));
        } else {
            std.mem.writeInt(u32, &buf, collect(&q, regs, size, off), .little);
            try cpu.bus.write(base +% off, &buf);
        }
    }
    if (load) for (0..regs) |r| mve.qreg.write(&cpu.fp.bank, @intCast(qd + r), q[r]);
    if (instr.hw1 >> 5 & 1 == 1) cpu.regs.set(rn, base +% @as(u32, regs) * 16);
    mve_beats.finishEci(cpu);
}

/// Spreads one loaded word's elements over the registers.
fn scatter(q: *[4]u128, regs: u3, size: Size, off: u32, word: u32) void {
    const step = mve.qreg.bits(size) / 8;
    var k: u32 = 0;
    while (k < 4) : (k += step) {
        const s = interleave.slot(regs, size, off + k);
        const value = if (step == 4) word else (word >> @intCast(k * 8)) & ((@as(u32, 1) << @intCast(step * 8)) - 1);
        q[s.reg] = mve.qreg.setElem(q[s.reg], size, s.elem, value);
    }
}

/// Gathers the elements one stored word takes from the registers.
fn collect(q: *const [4]u128, regs: u3, size: Size, off: u32) u32 {
    const step = mve.qreg.bits(size) / 8;
    var word: u32 = 0;
    var k: u32 = 0;
    while (k < 4) : (k += step) {
        const s = interleave.slot(regs, size, off + k);
        word |= mve.qreg.elem(q[s.reg], size, s.elem) << @intCast(k * 8);
    }
    return word;
}
