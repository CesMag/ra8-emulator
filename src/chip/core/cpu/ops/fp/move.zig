//! VMOV between core registers and the FP bank (T1): one core register
//! and one S register, or two core registers and either an S pair or one
//! D register. Bits move unchanged; FPSCR is untouched.
//!
//!   Sn <-> Rt          hw1 1110 1110 000 o Vn    hw2 Rt 1010 N 00 1 0000
//!   Sm, Sm+1 <-> Rt,Rt2 hw1 1110 1100 010 o Rt2  hw2 Rt 1010 00 M 1 Vm
//!   Dm <-> Rt, Rt2      hw1 1110 1100 010 o Rt2  hw2 Rt 1011 00 M 1 Vm
//!
//! o set moves into the core registers. Sn is Vn:N, Sm is Vm:M and Dm is
//! M:Vm. SP or PC as a core register, the pair starting at S31, D16+ and
//! two equal destination core registers are UNPREDICTABLE and stay
//! unclaimed. VMOV.F16 (the Sn <-> Rt form with hw2 bits 11:8 = 1001)
//! moves only the low halfword: Rt or Sn gets Zeros(16):value.
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;
const fp_regs = @import("regs.zig");

pub const group: op.Group = .{ .name = "fp_move", .decode = decode, .oracle = false };

pub const Fields = struct { rt: u4, rt2: u4, fp: u5, to_core: bool };

pub fn single(instr: Instr) Fields {
    return .{
        .rt = @intCast(instr.hw2 >> 12),
        .rt2 = 0,
        .fp = fp_regs.index(@intCast(instr.hw1 & 0xF), @intCast(instr.hw2 >> 7 & 1), false),
        .to_core = instr.hw1 >> 4 & 1 == 1,
    };
}

pub fn pair(instr: Instr) Fields {
    const double = instr.hw2 >> 8 & 1 == 1;
    return .{
        .rt = @intCast(instr.hw2 >> 12),
        .rt2 = @intCast(instr.hw1 & 0xF),
        .fp = fp_regs.index(@intCast(instr.hw2 & 0xF), @intCast(instr.hw2 >> 5 & 1), double),
        .to_core = instr.hw1 >> 4 & 1 == 1,
    };
}

fn unpredictable(r: u4) bool {
    return r == 13 or r == 15;
}

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4) return null;
    if (instr.hw1 & 0xFFE0 == 0xEE00 and instr.hw2 & 0x0C7F == 0x0810) {
        if (unpredictable(single(instr).rt)) return null;
        return switch (instr.hw2 >> 8 & 0xF) {
            0b1010 => &moveSingle,
            0b1001 => &moveHalf,
            else => null,
        };
    }
    if (instr.hw1 & 0xFFE0 != 0xEC40 or instr.hw2 & 0x0ED0 != 0x0A10) return null;
    const f = pair(instr);
    if (unpredictable(f.rt) or unpredictable(f.rt2)) return null;
    if (f.to_core and f.rt == f.rt2) return null;
    if (instr.hw2 >> 8 & 1 == 1) {
        if (!fp_regs.exists(f.fp, true)) return null;
        return &moveDouble;
    }
    if (f.fp == 31) return null;
    return &movePair;
}

fn moveSingle(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = single(instr);
    if (f.to_core) return cpu.regs.set(f.rt, cpu.fp.bank.readS(f.fp));
    cpu.fp.bank.writeS(f.fp, cpu.regs.get(f.rt));
}

fn moveHalf(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = single(instr);
    if (f.to_core) return cpu.regs.set(f.rt, cpu.fp.bank.readS(f.fp) & 0xFFFF);
    cpu.fp.bank.writeS(f.fp, cpu.regs.get(f.rt) & 0xFFFF);
}

fn movePair(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = pair(instr);
    if (f.to_core) {
        cpu.regs.set(f.rt, cpu.fp.bank.readS(f.fp));
        cpu.regs.set(f.rt2, cpu.fp.bank.readS(f.fp + 1));
        return;
    }
    cpu.fp.bank.writeSPair(f.fp, cpu.regs.get(f.rt), cpu.regs.get(f.rt2));
}

fn moveDouble(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = pair(instr);
    const d: u4 = @intCast(f.fp);
    if (f.to_core) {
        const words = cpu.fp.bank.readCorePair(d);
        cpu.regs.set(f.rt, words[0]);
        cpu.regs.set(f.rt2, words[1]);
        return;
    }
    cpu.fp.bank.writeCorePair(d, cpu.regs.get(f.rt), cpu.regs.get(f.rt2));
}
