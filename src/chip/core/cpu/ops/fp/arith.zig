//! The FPv5 three-register data-processing instructions (T1), single and
//! double precision: VMLA, VMLS, VNMLA, VNMLS, VMUL, VNMUL, VADD, VSUB,
//! VDIV, VFMA, VFMS, VFNMA and VFNMS. Each runs the matching pure function
//! from src/chip/core/cpu/fpu/ on the core's register bank and FPSCR.
//!
//! hw1 is 1110 1110 o D oo Vn and hw2 is Vd 101 sz N op M 0 Vm, where o:oo
//! and op pick the operation. Registers are Vx:X in single precision and
//! X:Vx in double, so a double with D, N or M set names D16 or above, which
//! M-profile does not have; those, and the encodings this table leaves
//! empty, stay unclaimed. Half precision (hw2 bits 11-8 1001) uses the
//! single register layout: operands are S[x]<15:0> and the result is
//! written as Zeros(16):result. FZ16 rather than FZ flushes them.
//! The CPACR enable check (NOCP) is not modelled yet.
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;
const fpu = @import("../../fpu/all.zig");
const Format = fpu.format.Format;
const Fpscr = fpu.fpscr.Fpscr;
const Bank = fpu.bank.Bank;

pub const group: op.Group = .{ .name = "fp_arith", .decode = decode, .oracle = false };

pub const Kind = enum { mla, mls, nmla, nmls, mul, nmul, add, sub, div, fma, fms, fnma, fnms };

/// The operation o:oo (hw1 bits 7, 5, 4) and op (hw2 bit 6) select.
pub fn kindOf(instr: Instr) ?Kind {
    const key: u3 = @intCast((instr.hw1 >> 5 & 0b100) | (instr.hw1 >> 4 & 0b11));
    const neg = instr.hw2 >> 6 & 1 == 1;
    return switch (key) {
        0b000 => if (neg) .mls else .mla,
        0b001 => if (neg) .nmla else .nmls,
        0b010 => if (neg) .nmul else .mul,
        0b011 => if (neg) .sub else .add,
        0b100 => if (neg) null else .div,
        0b101 => if (neg) .fnma else .fnms,
        0b110 => if (neg) .fms else .fma,
        else => null,
    };
}

pub const Fields = struct { d: u5, n: u5, m: u5 };

pub fn fields(instr: Instr, double: bool) Fields {
    const vd: u5 = @intCast(instr.hw2 >> 12 & 0xF);
    const vn: u5 = @intCast(instr.hw1 & 0xF);
    const vm: u5 = @intCast(instr.hw2 & 0xF);
    const d: u5 = @intCast(instr.hw1 >> 6 & 1);
    const n: u5 = @intCast(instr.hw2 >> 7 & 1);
    const m: u5 = @intCast(instr.hw2 >> 5 & 1);
    if (double) return .{ .d = d << 4 | vd, .n = n << 4 | vn, .m = m << 4 | vm };
    return .{ .d = vd << 1 | d, .n = vn << 1 | n, .m = vm << 1 | m };
}

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4 or instr.hw1 & 0xFF00 != 0xEE00) return null;
    const half = instr.hw2 & 0x0F10 == 0x0900;
    if (!half and instr.hw2 & 0x0E10 != 0x0A00) return null;
    const kind = kindOf(instr) orelse return null;
    if (half) return switch (kind) {
        inline else => |k| execFor(k, fpu.format.half),
    };
    const double = instr.hw2 >> 8 & 1 == 1;
    if (double) {
        const f = fields(instr, true);
        if (f.d > 15 or f.n > 15 or f.m > 15) return null;
    }
    return switch (kind) {
        inline else => |k| if (double) execFor(k, fpu.format.double) else execFor(k, fpu.format.single),
    };
}

fn execFor(comptime kind: Kind, comptime fmt: Format) op.Exec {
    return switch (kind) {
        .mla => ternary(fmt, fpu.mac.mla),
        .mls => ternary(fmt, fpu.mac.mls),
        .nmla => ternary(fmt, fpu.mac.nmla),
        .nmls => ternary(fmt, fpu.mac.nmls),
        .fma => ternary(fmt, fpu.fma.vfma),
        .fms => ternary(fmt, fpu.fma.vfms),
        .fnma => ternary(fmt, fpu.fma.vfnma),
        .fnms => ternary(fmt, fpu.fma.vfnms),
        .mul => binary(fmt, fpu.mul.mul),
        .nmul => binary(fmt, fpu.mul.nmul),
        .add => binary(fmt, fpu.add.add),
        .sub => binary(fmt, fpu.add.sub),
        .div => binary(fmt, fpu.div.div),
    };
}

fn binary(comptime fmt: Format, comptime f: anytype) op.Exec {
    return struct {
        fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
            const r = fields(instr, comptime fmt.width() == 64);
            const bank = &cpu.fp.bank;
            write(fmt, bank, r.d, f(fmt, read(fmt, bank, r.n), read(fmt, bank, r.m), &cpu.fp.fpscr));
        }
    }.exec;
}

fn ternary(comptime fmt: Format, comptime f: anytype) op.Exec {
    return struct {
        fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
            const r = fields(instr, comptime fmt.width() == 64);
            const bank = &cpu.fp.bank;
            const result = f(fmt, read(fmt, bank, r.d), read(fmt, bank, r.n), read(fmt, bank, r.m), &cpu.fp.fpscr);
            write(fmt, bank, r.d, result);
        }
    }.exec;
}

fn read(comptime fmt: Format, bank: *const Bank, index: u5) fmt.Bits() {
    if (comptime fmt.width() == 64) return bank.readD(@intCast(index));
    if (comptime fmt.width() == 16) return @truncate(bank.readS(index));
    return bank.readS(index);
}

fn write(comptime fmt: Format, bank: *Bank, index: u5, value: fmt.Bits()) void {
    if (comptime fmt.width() == 64) return bank.writeD(@intCast(index), value);
    bank.writeS(index, value);
}
