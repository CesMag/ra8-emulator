//! The FPv5 VCVT family (T1): between single and double precision, float
//! to S32/U32 (VCVT rounds toward zero, VCVTR uses FPSCR.RMode), S32/U32 to
//! float, float to and from 16- or 32-bit fixed point, and VCVTB/VCVTT to
//! and from a half-precision lane. Each runs the matching pure function
//! from src/chip/core/cpu/fpu/ on the core's bank and FPSCR.
//!
//! hw1 is 1110 1110 1 D 11 opc2 and hw2 is Vd 101 sz o 1 M 0 Vm. opc2
//! picks the conversion; o is the VCVT/VCVTR choice, the integer source's
//! signedness, the fixed-point width (sx) or the half lane (T). The
//! fixed-point forms convert Vd in place: M is the low bit of imm5 and Vm
//! its top four, with fraction bits = width - imm5. A negative fraction
//! count, a D16+ double and opc2 0111 with o clear stay unclaimed.
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;
const fpu = @import("../../fpu/all.zig");
const Format = fpu.format.Format;
const fp_regs = @import("regs.zig");

pub const group: op.Group = .{ .name = "fp_convert", .decode = decode, .oracle = false };

pub const Kind = enum { precision, to_int, from_int, to_fixed, from_fixed, from_half, to_half };

pub fn kindOf(instr: Instr) ?Kind {
    const o = instr.hw2 >> 7 & 1 == 1;
    return switch (instr.hw1 & 0xF) {
        0b0111 => if (o) .precision else null,
        0b1100, 0b1101 => .to_int,
        0b1000 => .from_int,
        0b1010, 0b1011 => .from_fixed,
        0b1110, 0b1111 => .to_fixed,
        0b0010 => .from_half,
        0b0011 => .to_half,
        else => null,
    };
}

/// Which operands are double precision for a kind, given sz. A fixed-point
/// form has no separate source, so its m follows d.
pub const Widths = struct { d: bool, m: bool };

pub fn widths(kind: Kind, sz: bool) Widths {
    return switch (kind) {
        .precision => .{ .d = !sz, .m = sz },
        .to_int, .to_half => .{ .d = false, .m = sz },
        .from_int, .from_half => .{ .d = sz, .m = false },
        .to_fixed, .from_fixed => .{ .d = sz, .m = sz },
    };
}

/// The fixed-point integer width and fraction bits, or null when imm5 is
/// wider than the integer.
pub const Fixed = struct { width: u6, fbits: u6 };

pub fn fixedOf(instr: Instr) ?Fixed {
    const width: u6 = if (instr.hw2 >> 7 & 1 == 1) 32 else 16;
    const imm5: u6 = @intCast((instr.hw2 & 0xF) << 1 | (instr.hw2 >> 5 & 1));
    if (imm5 > width) return null;
    return .{ .width = width, .fbits = width - imm5 };
}

pub fn dReg(instr: Instr, double: bool) u5 {
    return fp_regs.index(@intCast(instr.hw2 >> 12), @intCast(instr.hw1 >> 6 & 1), double);
}

pub fn mReg(instr: Instr, double: bool) u5 {
    return fp_regs.index(@intCast(instr.hw2 & 0xF), @intCast(instr.hw2 >> 5 & 1), double);
}

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4 or instr.hw1 & 0xFFB0 != 0xEEB0) return null;
    if (instr.hw2 & 0x0E50 != 0x0A40) return null;
    const kind = kindOf(instr) orelse return null;
    const sz = instr.hw2 >> 8 & 1 == 1;
    const w = widths(kind, sz);
    if (!fp_regs.exists(dReg(instr, w.d), w.d)) return null;
    switch (kind) {
        .to_fixed, .from_fixed => if (fixedOf(instr) == null) return null,
        else => if (!fp_regs.exists(mReg(instr, w.m), w.m)) return null,
    }
    return switch (kind) {
        inline else => |k| if (sz) execFor(k, true) else execFor(k, false),
    };
}

fn execFor(comptime kind: Kind, comptime sz: bool) op.Exec {
    return struct {
        fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
            switch (kind) {
                .precision => precision(cpu, instr, sz),
                .to_int => toInt(cpu, instr, sz),
                .from_int => fromInt(cpu, instr, sz),
                .to_fixed => toFixed(cpu, instr, sz),
                .from_fixed => fromFixed(cpu, instr, sz),
                .from_half => fromHalf(cpu, instr, sz),
                .to_half => toHalf(cpu, instr, sz),
            }
        }
    }.exec;
}

fn fmtOf(comptime double: bool) Format {
    return if (double) fpu.format.double else fpu.format.single;
}

fn precision(cpu: *Cpu, instr: Instr, comptime sz: bool) void {
    const from = comptime fmtOf(sz);
    const to = comptime fmtOf(!sz);
    const value = fp_regs.read(from, &cpu.fp.bank, mReg(instr, sz));
    fp_regs.write(to, &cpu.fp.bank, dReg(instr, !sz), fpu.convert.convert(from, to, value, &cpu.fp.fpscr));
}

fn toInt(cpu: *Cpu, instr: Instr, comptime sz: bool) void {
    const fmt = comptime fmtOf(sz);
    const unsigned = instr.hw1 & 1 == 0;
    const mode: fpu.fpscr.RMode = if (instr.hw2 >> 7 & 1 == 1) .zero else cpu.fp.fpscr.rmode;
    const value = fp_regs.read(fmt, &cpu.fp.bank, mReg(instr, sz));
    const word = fpu.to_int.toFixed(fmt, value, 0, unsigned, mode, &cpu.fp.fpscr);
    fp_regs.write(fpu.format.single, &cpu.fp.bank, dReg(instr, false), word);
}

fn fromInt(cpu: *Cpu, instr: Instr, comptime sz: bool) void {
    const fmt = comptime fmtOf(sz);
    const unsigned = instr.hw2 >> 7 & 1 == 0;
    const word = fp_regs.read(fpu.format.single, &cpu.fp.bank, mReg(instr, false));
    const result = fpu.from_int.fromFixed(fmt, word, 0, unsigned, cpu.fp.fpscr.rmode, &cpu.fp.fpscr);
    fp_regs.write(fmt, &cpu.fp.bank, dReg(instr, sz), result);
}

fn toFixed(cpu: *Cpu, instr: Instr, comptime sz: bool) void {
    const fmt = comptime fmtOf(sz);
    const f = fixedOf(instr).?;
    const unsigned = instr.hw1 & 1 == 1;
    const d = dReg(instr, sz);
    const word = fpu.fixed.toFixed(fmt, fp_regs.read(fmt, &cpu.fp.bank, d), f.width, f.fbits, unsigned, &cpu.fp.fpscr);
    fp_regs.write(fmt, &cpu.fp.bank, d, extend(fmt, word, unsigned));
}

/// A double destination takes the result extended to 64 bits.
pub fn extend(comptime fmt: Format, word: u32, unsigned: bool) fmt.Bits() {
    if (comptime fmt.width() == 32) return word;
    if (unsigned) return word;
    const signed: i32 = @bitCast(word);
    return @bitCast(@as(i64, signed));
}

fn fromFixed(cpu: *Cpu, instr: Instr, comptime sz: bool) void {
    const fmt = comptime fmtOf(sz);
    const f = fixedOf(instr).?;
    const unsigned = instr.hw1 & 1 == 1;
    const d = dReg(instr, sz);
    const word: u32 = @truncate(fp_regs.read(fmt, &cpu.fp.bank, d));
    const result = fpu.fixed.fromFixed(fmt, word, f.width, f.fbits, unsigned, cpu.fp.fpscr.rmode, &cpu.fp.fpscr);
    fp_regs.write(fmt, &cpu.fp.bank, d, result);
}

fn fromHalf(cpu: *Cpu, instr: Instr, comptime sz: bool) void {
    const fmt = comptime fmtOf(sz);
    const top = instr.hw2 >> 7 & 1 == 1;
    const lane = fpu.half.lane(fp_regs.read(fpu.format.single, &cpu.fp.bank, mReg(instr, false)), top);
    fp_regs.write(fmt, &cpu.fp.bank, dReg(instr, sz), fpu.half.fromHalf(fmt, lane, &cpu.fp.fpscr));
}

fn toHalf(cpu: *Cpu, instr: Instr, comptime sz: bool) void {
    const fmt = comptime fmtOf(sz);
    const top = instr.hw2 >> 7 & 1 == 1;
    const value = fpu.half.toHalf(fmt, fp_regs.read(fmt, &cpu.fp.bank, mReg(instr, sz)), &cpu.fp.fpscr);
    const d = dReg(instr, false);
    const word = fp_regs.read(fpu.format.single, &cpu.fp.bank, d);
    fp_regs.write(fpu.format.single, &cpu.fp.bank, d, fpu.half.place(word, value, top));
}
