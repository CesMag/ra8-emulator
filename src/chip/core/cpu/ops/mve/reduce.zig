//! MVE across-vector reductions into the decoder (RA8EMU-632): VADDV{A},
//! VADDLV{A}, VMLADAV{A}{X}, VMLSDAV{A}{X}, VMLALDAV{A}{X} and
//! VMLSLDAV{A}{X}. Encodings per GNU as for armv8.1-m.main+mve.
//! hw1 111U 1110 1111 low writes one register (Rda, even): with hw2[8] set,
//! low sz01 is VADDV and Qn:0 is the 8-bit VMLADAV; with hw2[8] clear,
//! Qn:sz is VMLADAV .16/.32, and U with the subtract bit is the 8-bit
//! VMLSDAV. hw1 111U 1110 1 RdaHi low writes a pair (RdaHi odd): low 1001
//! with hw2[8] set is VADDLV, Qn:sz with hw2[8] clear is VMLALDAV.
//! hw2 Rda X 111 b8 0 0 A 0 Qm sub. U with X, U with a 16/32 subtract,
//! RdaHi of SP and the VRMLALDAVH space stay unclaimed. Only active
//! elements of Qm add in; the instruction advances the VPT block.
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;
const mve = @import("../../mve/all.zig");
const mve_beats = @import("beats.zig");
const Size = mve.qreg.Size;
const reduce = mve.reduce;

pub const group: op.Group = .{ .name = "mve_reduce", .decode = decode, .oracle = false };

pub const encodings = struct {
    /// U and everything below bit 8 masked out.
    pub const hw1_mask: u16 = 0xEF00;
    pub const hw1: u16 = 0xEE00;
    /// Rda, X, b8, A, Qm and sub masked out.
    pub const hw2_mask: u16 = 0x0ED0;
    pub const hw2: u16 = 0x0E00;
};

pub const Kind = enum { addv, addlv, mladav, mlaldav };

pub const Fields = struct {
    kind: Kind,
    size: Size,
    unsigned: bool = false,
    accumulate: bool,
    dual: reduce.Dual = .{},
    rda: u4,
    rda_hi: u4 = 0,
    qn: u3 = 0,
    qm: u3,
};

fn bit(v: u16, n: u4) bool {
    return v >> n & 1 == 1;
}

/// The form an encoding names, or null when this group does not claim it.
pub fn fieldsOf(instr: Instr) ?Fields {
    if (instr.size != 4) return null;
    if (instr.hw1 & encodings.hw1_mask != encodings.hw1) return null;
    if (instr.hw2 & encodings.hw2_mask != encodings.hw2) return null;
    var f: Fields = .{
        .kind = .addv,
        .size = .word,
        .accumulate = bit(instr.hw2, 5),
        .rda = @intCast((instr.hw2 >> 13) * 2),
        .qm = @intCast(instr.hw2 >> 1 & 7),
    };
    if (instr.hw1 & 0x00F0 == 0x00F0) return single(instr, &f);
    if (bit(instr.hw1, 7)) return pair(instr, &f);
    return null;
}

fn single(instr: Instr, f: *Fields) ?Fields {
    const u = bit(instr.hw1, 12);
    const x = bit(instr.hw2, 12);
    const sub = bit(instr.hw2, 0);
    const low = instr.hw1 & 0xF;
    f.qn = @intCast(low >> 1);
    f.kind = .mladav;
    if (bit(instr.hw2, 8)) {
        if (low & 1 == 1) {
            if (low & 2 != 0 or x or sub) return null;
            f.kind = .addv;
            f.size = sizeOf(low >> 2) orelse return null;
            f.unsigned = u;
            return f.*;
        }
        if (sub or (u and x)) return null;
        f.size = .byte;
        f.unsigned = u;
    } else if (sub and u) {
        if (low & 1 == 1) return null;
        f.size = .byte;
    } else {
        if (u and x) return null;
        f.size = if (low & 1 == 1) .word else .half;
        f.unsigned = u;
    }
    f.dual = .{ .unsigned = f.unsigned, .exchange = x, .subtract = sub };
    return f.*;
}

fn pair(instr: Instr, f: *Fields) ?Fields {
    const u = bit(instr.hw1, 12);
    const x = bit(instr.hw2, 12);
    const sub = bit(instr.hw2, 0);
    const hi: u4 = @intCast(instr.hw1 >> 4 & 7);
    if (hi == 6) return null;
    f.rda_hi = hi * 2 + 1;
    f.unsigned = u;
    const low = instr.hw1 & 0xF;
    if (bit(instr.hw2, 8)) {
        if (low != 0b1001 or x or sub) return null;
        f.kind = .addlv;
        return f.*;
    }
    if (u and (x or sub)) return null;
    f.kind = .mlaldav;
    f.qn = @intCast(low >> 1);
    f.size = if (low & 1 == 1) .word else .half;
    f.dual = .{ .unsigned = u, .exchange = x, .subtract = sub };
    return f.*;
}

fn sizeOf(sz: u16) ?Size {
    return switch (sz) {
        0 => .byte,
        1 => .half,
        2 => .word,
        else => null,
    };
}

/// `a` with the elements `mask` leaves inactive cleared, so they add 0.
pub fn activeOnly(a: u128, size: Size, mask: u16) u128 {
    const n = mve.qreg.lanes(size);
    const width: u4 = @intCast(16 / n);
    var bytes: u16 = 0;
    for (0..n) |k| {
        const e: u8 = @intCast(k);
        if (!mve.predicate.active(mask, size, e)) continue;
        const ones: u16 = (@as(u16, 1) << width) - 1;
        bytes |= ones << @intCast(@as(u16, e) * width);
    }
    return mve.predicate.merge(0, a, bytes);
}

fn decode(instr: Instr) ?op.Exec {
    _ = fieldsOf(instr) orelse return null;
    return exec;
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = fieldsOf(instr).?;
    const bank = &cpu.fp.bank;
    const qm = activeOnly(mve.qreg.read(bank, f.qm), f.size, mve_beats.mask(cpu));
    const qn = mve.qreg.read(bank, f.qn);
    switch (f.kind) {
        .addv, .mladav => {
            const acc: u32 = if (f.accumulate) cpu.regs.get(f.rda) else 0;
            const r = if (f.kind == .addv)
                reduce.addv(acc, qm, f.size, f.unsigned)
            else
                reduce.mladav(acc, qm, qn, f.size, f.dual);
            cpu.regs.set(f.rda, r);
        },
        .addlv, .mlaldav => {
            const old = @as(u64, cpu.regs.get(f.rda_hi)) << 32 | cpu.regs.get(f.rda);
            const acc: u64 = if (f.accumulate) old else 0;
            const r = if (f.kind == .addlv)
                reduce.addlv(acc, qm, f.unsigned)
            else
                reduce.mlaldav(acc, qm, qn, f.size, f.dual);
            cpu.regs.set(f.rda, @truncate(r));
            cpu.regs.set(f.rda_hi, @truncate(r >> 32));
        },
    }
    mve_beats.finish(cpu);
}
