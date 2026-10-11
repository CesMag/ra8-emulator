//! The FPv5 single-operand data-processing instructions (T1), single and
//! double precision: VMOV (immediate), VMOV (register), VABS, VNEG and
//! VSQRT. VMOV, VABS and VNEG move bits and leave FPSCR alone; VSQRT runs
//! the pure fpu.sqrt with the core's FPSCR.
//!
//! hw1 is 1110 1110 1 D 11 opc2 and hw2 is Vd 101 sz o 1 M 0 Vm, except the
//! immediate form, where opc2 is imm4H, hw2 bits 7:4 are 0000 and Vm is
//! imm4L. Registers are Vx:X in single precision and X:Vx in double, so a
//! double naming D16+ stays unclaimed, as do the should-be-zero bits of
//! the immediate form and every opc2 this group does not decode (VCMP,
//! VCVT, VRINT and the rest of the space). Half precision (hw2 bits 11-8
//! 1001) covers VMOV (immediate), VABS, VNEG and VSQRT on S[x]<15:0>,
//! writing Zeros(16):result; VMOV (register) has no half form.
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;
const fpu = @import("../../fpu/all.zig");
const Format = fpu.format.Format;
const fp_regs = @import("regs.zig");

pub const group: op.Group = .{ .name = "fp_unary", .decode = decode, .oracle = false };

pub const Kind = enum { mov_imm, mov, abs, neg, sqrt };

/// The operation opc2 (hw1 bits 3:0) and hw2 bits 7:6 select.
pub fn kindOf(instr: Instr) ?Kind {
    const opc2 = instr.hw1 & 0xF;
    const low = instr.hw2 >> 4 & 0xF;
    if (low == 0) return .mov_imm;
    if (low & 0b0100 == 0) return null;
    const o = low & 0b1000 != 0;
    return switch (opc2) {
        0b0000 => if (o) .abs else .mov,
        0b0001 => if (o) .sqrt else .neg,
        else => null,
    };
}

pub const Fields = struct { d: u5, m: u5 };

pub fn fields(instr: Instr, double: bool) Fields {
    const vd: u5 = @intCast(instr.hw2 >> 12 & 0xF);
    const vm: u5 = @intCast(instr.hw2 & 0xF);
    const d: u5 = @intCast(instr.hw1 >> 6 & 1);
    const m: u5 = @intCast(instr.hw2 >> 5 & 1);
    if (double) return .{ .d = d << 4 | vd, .m = m << 4 | vm };
    return .{ .d = vd << 1 | d, .m = vm << 1 | m };
}

/// imm4H:imm4L, the VFPExpandImm input of the immediate form.
pub fn imm8(instr: Instr) u8 {
    return @intCast((instr.hw1 & 0xF) << 4 | (instr.hw2 & 0xF));
}

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4 or instr.hw1 & 0xFFB0 != 0xEEB0) return null;
    const half = instr.hw2 & 0x0F10 == 0x0900;
    if (!half and instr.hw2 & 0x0E10 != 0x0A00) return null;
    const kind = kindOf(instr) orelse return null;
    if (half) return switch (kind) {
        .mov => null,
        inline else => |k| execFor(k, fpu.format.half),
    };
    const double = instr.hw2 >> 8 & 1 == 1;
    if (double) {
        const f = fields(instr, true);
        if (f.d > 15 or (kind != .mov_imm and f.m > 15)) return null;
    }
    return switch (kind) {
        inline else => |k| if (double) execFor(k, fpu.format.double) else execFor(k, fpu.format.single),
    };
}

fn execFor(comptime kind: Kind, comptime fmt: Format) op.Exec {
    return struct {
        fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
            const r = fields(instr, comptime fmt.width() == 64);
            const bank = &cpu.fp.bank;
            const value = fp_regs.read(fmt, bank, r.m);
            const result: fmt.Bits() = switch (kind) {
                .mov_imm => fpu.imm.expandImm(fmt, imm8(instr)),
                .mov => value,
                .abs => value & ~sign(fmt),
                .neg => value ^ sign(fmt),
                .sqrt => fpu.sqrt.sqrt(fmt, value, &cpu.fp.fpscr),
            };
            fp_regs.write(fmt, bank, r.d, result);
        }
    }.exec;
}

fn sign(comptime fmt: Format) fmt.Bits() {
    return @as(fmt.Bits(), 1) << (comptime fmt.width() - 1);
}
