//! 32-bit data processing with a shifted register (T2/T3 forms): AND, BIC,
//! ORR, ORN, EOR, ADD, ADC, SBC, SUB and RSB, Rd = Rn op shift(Rm), with the
//! aliases MOV/LSL/LSR/ASR/ROR/RRX and MVN (ORR and ORN with Rn of PC) and
//! TST, TEQ, CMN and CMP (AND, EOR, ADD and SUB with Rd of PC and S set).
//! The logical ops set N, Z and C from the shifter; the arithmetic ones set
//! NZCV. PKHBT/PKHTB is DSP and left for its own group.
//!
//! The UNPREDICTABLE register choices are left unclaimed, so the core stops
//! rather than guess. ADD and SUB with Rn of SP are allowed.
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;
const flags = @import("../../flags.zig");
const shift = @import("../../shift.zig");

pub const encodings = struct {
    /// Bits [15:9] of hw1.
    pub const mask: u16 = 0xFE00;
    pub const space: u16 = 0xEA00;
};

pub const opcodes = struct {
    pub const and_: u4 = 0b0000;
    pub const bic: u4 = 0b0001;
    pub const orr: u4 = 0b0010;
    pub const orn: u4 = 0b0011;
    pub const eor: u4 = 0b0100;
    pub const add: u4 = 0b1000;
    pub const adc: u4 = 0b1010;
    pub const sbc: u4 = 0b1011;
    pub const sub: u4 = 0b1101;
    pub const rsb: u4 = 0b1110;
};

pub const group: op.Group = .{ .name = "dp_shifted", .decode = decode };

pub const Fields = struct {
    opcode: u4,
    s: bool,
    rn: u4,
    rd: u4,
    rm: u4,
    kind: shift.Kind,
    imm5: u5,

    pub fn of(instr: Instr) ?Fields {
        if (instr.size != 4 or instr.hw1 & encodings.mask != encodings.space) return null;
        if (instr.hw2 & 0x8000 != 0) return null;
        const imm3: u5 = @intCast((instr.hw2 >> 12) & 0x7);
        const imm2: u5 = @intCast((instr.hw2 >> 6) & 0x3);
        return .{
            .opcode = @intCast((instr.hw1 >> 5) & 0xF),
            .s = instr.hw1 & 0x10 != 0,
            .rn = @intCast(instr.hw1 & 0xF),
            .rd = @intCast((instr.hw2 >> 8) & 0xF),
            .rm = @intCast(instr.hw2 & 0xF),
            .kind = @fromBackingInt(@intCast((instr.hw2 >> 4) & 0x3)),
            .imm5 = (imm3 << 2) | imm2,
        };
    }
};

fn spOrPc(n: u4) bool {
    return n == 13 or n == 15;
}

fn logical(opcode: u4) bool {
    return opcode <= opcodes.eor;
}

fn known(opcode: u4) bool {
    return switch (opcode) {
        opcodes.and_, opcodes.bic, opcodes.orr, opcodes.orn, opcodes.eor => true,
        opcodes.add, opcodes.adc, opcodes.sbc, opcodes.sub, opcodes.rsb => true,
        else => false,
    };
}

/// Whether the register choices are architecturally defined for `f`.
pub fn allowed(f: Fields) bool {
    if (!known(f.opcode) or spOrPc(f.rm)) return false;
    const moves = f.opcode == opcodes.orr or f.opcode == opcodes.orn;
    if (moves and f.rn == 15) return !spOrPc(f.rd);
    const compares = switch (f.opcode) {
        opcodes.and_, opcodes.eor, opcodes.add, opcodes.sub => true,
        else => false,
    };
    if (compares and f.rd == 15 and f.s) return f.rn != 15;
    const add_sub = f.opcode == opcodes.add or f.opcode == opcodes.sub;
    if (add_sub and f.rn == 13) return f.rd != 15;
    return !spOrPc(f.rd) and !spOrPc(f.rn);
}

fn decode(instr: Instr) ?op.Exec {
    const f = Fields.of(instr) orelse return null;
    return if (allowed(f)) exec else null;
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = Fields.of(instr).?;
    const carry = flags.carry(&cpu.regs);
    const m = shift.immShiftC(cpu.regs.get(f.rm), f.kind, f.imm5, carry);
    const n: u32 = if (f.rn == 15) 0 else cpu.regs.get(f.rn);
    if (logical(f.opcode)) {
        const result = switch (f.opcode) {
            opcodes.and_ => n & m.result,
            opcodes.bic => n & ~m.result,
            opcodes.orr => n | m.result,
            opcodes.orn => n | ~m.result,
            else => n ^ m.result,
        };
        if (f.rd != 15) cpu.regs.set(f.rd, result);
        if (f.s) flags.setNZC(&cpu.regs, result, m.carry);
        return;
    }
    const sum = switch (f.opcode) {
        opcodes.add => flags.addWithCarry(n, m.result, false),
        opcodes.adc => flags.addWithCarry(n, m.result, carry),
        opcodes.sbc => flags.addWithCarry(n, ~m.result, carry),
        opcodes.sub => flags.addWithCarry(n, ~m.result, true),
        else => flags.addWithCarry(~n, m.result, true),
    };
    if (f.rd != 15) cpu.regs.set(f.rd, sum.result);
    if (f.s) flags.setNZCV(&cpu.regs, sum);
}
