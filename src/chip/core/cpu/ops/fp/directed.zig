//! The FPv5 instructions with the rounding or condition in the encoding,
//! single and double precision: VSEL (on the APSR flags), VMAXNM/VMINNM,
//! VRINTA/N/P/M and VCVTA/N/P/M to S32/U32, plus the conditional VRINTR,
//! VRINTZ and VRINTX, which take FPSCR's mode or round toward zero.
//!
//! hw2 is Vd 101 sz N o M 0 Vm throughout. hw1:
//!   VSEL          1111 1110 0 D cc Vn     (o = 0)
//!   VMAXNM/VMINNM 1111 1110 1 D 00 Vn     (o = min)
//!   VRINTA/N/P/M  1111 1110 1 D 11 10 rm  (N = 0, o = 1)
//!   VCVTA/N/P/M   1111 1110 1 D 11 11 rm  (o = 1, N = signed)
//!   VRINTR/Z      1110 1110 1 D 11 0110   (o = 1, N = toward zero)
//!   VRINTX        1110 1110 1 D 11 0111   (N = 0, o = 1)
//! rm is 00 ties away, 01 nearest, 10 toward +inf, 11 toward -inf. Every
//! form also has an F16 encoding (hw2 bits 11:8 = 1001), which uses the
//! single register numbering, reads S[i]<15:0> and writes Zeros(16):value;
//! VCVT from F16 still writes a full S32/U32 word. D16+ and every other bit
//! pattern stay unclaimed.
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;
const fpu = @import("../../fpu/all.zig");
const Format = fpu.format.Format;
const Rounding = fpu.rounding.Rounding;
const fp_regs = @import("regs.zig");

pub const group: op.Group = .{ .name = "fp_directed", .decode = decode, .oracle = false };

pub const Kind = enum { sel, maxmin, rint_rm, cvt_rm, rint_rz, rint_x };

pub fn kindOf(instr: Instr) ?Kind {
    const n = instr.hw2 >> 7 & 1;
    const o = instr.hw2 >> 6 & 1;
    const h = instr.hw1;
    if (h & 0xFF80 == 0xFE00) return if (o == 0) .sel else null;
    if (h & 0xFFB0 == 0xFE80) return .maxmin;
    if (o == 0) return null;
    if (h & 0xFFBC == 0xFEB8) return if (n == 0) .rint_rm else null;
    if (h & 0xFFBC == 0xFEBC) return .cvt_rm;
    if (h & 0xFFBF == 0xEEB6) return .rint_rz;
    if (h & 0xFFBF == 0xEEB7) return if (n == 0) .rint_x else null;
    return null;
}

/// The rounding hw1 bits 1:0 name for the VRINT and VCVT directed forms.
pub fn roundingOf(rm: u2) Rounding {
    return switch (rm) {
        0b00 => .ties_away,
        0b01 => .nearest,
        0b10 => .plus_inf,
        0b11 => .minus_inf,
    };
}

pub fn dReg(instr: Instr, double: bool) u5 {
    return fp_regs.index(@intCast(instr.hw2 >> 12), @intCast(instr.hw1 >> 6 & 1), double);
}

pub fn nReg(instr: Instr, double: bool) u5 {
    return fp_regs.index(@intCast(instr.hw1 & 0xF), @intCast(instr.hw2 >> 7 & 1), double);
}

pub fn mReg(instr: Instr, double: bool) u5 {
    return fp_regs.index(@intCast(instr.hw2 & 0xF), @intCast(instr.hw2 >> 5 & 1), double);
}

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4) return null;
    const half = instr.hw2 & 0x0F10 == 0x0900;
    if (!half and instr.hw2 & 0x0E10 != 0x0A00) return null;
    const kind = kindOf(instr) orelse return null;
    if (half) return switch (kind) {
        inline else => |k| execFor(k, fpu.format.half),
    };
    const double = instr.hw2 >> 8 & 1 == 1;
    const d_double = double and kind != .cvt_rm;
    if (!fp_regs.exists(dReg(instr, d_double), d_double)) return null;
    if (!fp_regs.exists(mReg(instr, double), double)) return null;
    if ((kind == .sel or kind == .maxmin) and !fp_regs.exists(nReg(instr, double), double)) return null;
    return switch (kind) {
        inline else => |k| if (double) execFor(k, fpu.format.double) else execFor(k, fpu.format.single),
    };
}

fn execFor(comptime kind: Kind, comptime fmt: Format) op.Exec {
    return struct {
        fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
            const double = comptime fmt.width() == 64;
            const bank = &cpu.fp.bank;
            const fpscr = &cpu.fp.fpscr;
            const m = fp_regs.read(fmt, bank, mReg(instr, double));
            const rm: u2 = @intCast(instr.hw1 & 0b11);
            const result: fmt.Bits() = switch (kind) {
                .sel => sel(fmt, cpu, instr, m),
                .maxmin => blk: {
                    const which: fpu.minmax.Which = if (instr.hw2 >> 6 & 1 == 1) .min else .max;
                    break :blk fpu.minmax.num(fmt, fp_regs.read(fmt, bank, nReg(instr, double)), m, which, fpscr);
                },
                .rint_rm => fpu.rint.rint(fmt, m, roundingOf(rm), false, fpscr),
                .rint_rz => blk: {
                    const r: Rounding = if (instr.hw2 >> 7 & 1 == 1) .zero else Rounding.of(fpscr.rmode);
                    break :blk fpu.rint.rint(fmt, m, r, false, fpscr);
                },
                .rint_x => fpu.rint.rint(fmt, m, Rounding.of(fpscr.rmode), true, fpscr),
                .cvt_rm => {
                    const unsigned = instr.hw2 >> 7 & 1 == 0;
                    const word = fpu.to_int.toFixedBy(fmt, m, 0, unsigned, roundingOf(rm), fpscr);
                    fp_regs.write(fpu.format.single, bank, dReg(instr, false), word);
                    return;
                },
            };
            fp_regs.write(fmt, bank, dReg(instr, double), result);
        }
    }.exec;
}

fn sel(comptime fmt: Format, cpu: *Cpu, instr: Instr, m: fmt.Bits()) fmt.Bits() {
    const double = comptime fmt.width() == 64;
    const cond: fpu.select.Cond = @fromBackingInt(@intCast(instr.hw1 >> 4 & 0b11));
    const nzcv: u4 = @intCast(cpu.regs.xpsr >> 28);
    const n = fp_regs.read(fmt, &cpu.fp.bank, nReg(instr, double));
    return fpu.select.select(fmt.Bits(), cond, nzcv, n, m);
}
