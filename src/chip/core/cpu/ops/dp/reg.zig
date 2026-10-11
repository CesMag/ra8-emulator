//! The 16-bit data-processing register block (0x4000-0x43FF): AND, EOR,
//! LSL/LSR/ASR/ROR by register, ADC, SBC, TST, RSB #0, CMP, CMN, ORR, MUL,
//! BIC and MVN, all T1 with Rdn in [2:0] and Rm in [5:3]. TST, CMP and CMN
//! always set the flags; the rest set them only outside an IT block.
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;
const flags = @import("../../flags.zig");
const shift = @import("../../shift.zig");

pub const encodings = struct {
    pub const mask: u16 = 0xFC00;
    pub const block: u16 = 0x4000;
};

/// Bits [9:6], in Arm ARM order.
pub const Opcode = enum(u4) {
    and_ = 0x0,
    eor = 0x1,
    lsl = 0x2,
    lsr = 0x3,
    asr = 0x4,
    adc = 0x5,
    sbc = 0x6,
    ror = 0x7,
    tst = 0x8,
    rsb = 0x9,
    cmp = 0xA,
    cmn = 0xB,
    orr = 0xC,
    mul = 0xD,
    bic = 0xE,
    mvn = 0xF,
};

pub const group: op.Group = .{ .name = "dp_reg", .decode = decode };

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 2 or instr.hw1 & encodings.mask != encodings.block) return null;
    return exec;
}

/// What an opcode leaves behind: the value, whether it is written back, and
/// which flags it produces.
const Outcome = struct {
    result: u32,
    write: bool = true,
    always_flags: bool = false,
    kind: enum { nz, nzc, nzcv } = .nz,
    carry: bool = false,
    overflow: bool = false,
};

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const opcode: Opcode = @fromBackingInt(@intCast((instr.hw1 >> 6) & 0xF));
    const rdn: u4 = @intCast(instr.hw1 & 0x7);
    const rm: u4 = @intCast((instr.hw1 >> 3) & 0x7);
    const out = compute(opcode, cpu.regs.get(rdn), cpu.regs.get(rm), flags.carry(&cpu.regs));
    if (out.write) cpu.regs.set(rdn, out.result);
    if (!out.always_flags and flags.inItBlock(&cpu.regs)) return;
    switch (out.kind) {
        .nz => flags.setNZ(&cpu.regs, out.result),
        .nzc => flags.setNZC(&cpu.regs, out.result, out.carry),
        .nzcv => flags.setNZCV(&cpu.regs, .{ .result = out.result, .carry = out.carry, .overflow = out.overflow }),
    }
}

fn arith(sum: flags.Sum, write: bool) Outcome {
    return .{
        .result = sum.result,
        .write = write,
        .always_flags = !write,
        .kind = .nzcv,
        .carry = sum.carry,
        .overflow = sum.overflow,
    };
}

fn shifted(value: u32, kind: shift.Kind, rm: u32, carry_in: bool) Outcome {
    const out = shift.shiftC(value, kind, rm & 0xFF, carry_in);
    return .{ .result = out.result, .kind = .nzc, .carry = out.carry };
}

/// x is Rdn, y is Rm. Logical ops and MUL leave C (and V) alone, which the
/// .nz kind does by not touching them.
pub fn compute(opcode: Opcode, x: u32, y: u32, carry_in: bool) Outcome {
    return switch (opcode) {
        .and_ => .{ .result = x & y },
        .eor => .{ .result = x ^ y },
        .orr => .{ .result = x | y },
        .bic => .{ .result = x & ~y },
        .mvn => .{ .result = ~y },
        .mul => .{ .result = x *% y },
        .tst => .{ .result = x & y, .write = false, .always_flags = true },
        .lsl => shifted(x, .lsl, y, carry_in),
        .lsr => shifted(x, .lsr, y, carry_in),
        .asr => shifted(x, .asr, y, carry_in),
        .ror => shifted(x, .ror, y, carry_in),
        .adc => arith(flags.addWithCarry(x, y, carry_in), true),
        .sbc => arith(flags.addWithCarry(x, ~y, carry_in), true),
        // RSB Rd, Rn, #0: Rd is [2:0], Rn is [5:3], so the operand is y.
        .rsb => arith(flags.addWithCarry(~y, 0, true), true),
        .cmp => arith(flags.addWithCarry(x, ~y, true), false),
        .cmn => arith(flags.addWithCarry(x, y, false), false),
    };
}
