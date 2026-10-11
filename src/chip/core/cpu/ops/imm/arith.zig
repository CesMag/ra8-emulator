//! The arithmetic 32-bit data processing (modified immediate) forms: ADD,
//! ADC, SBC, SUB and RSB, with CMN and CMP (ADD and SUB with Rd of PC and S
//! set) and the SP forms of ADD and SUB. With S set they write NZCV.
//!
//! The UNPREDICTABLE register choices and immediates are left unclaimed, so
//! the core stops rather than guess.
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;
const flags = @import("../../flags.zig");
const thumb_imm = @import("../../thumb_imm.zig");
const Fields = @import("fields.zig").Fields;

pub const opcodes = struct {
    pub const add: u4 = 0b1000;
    pub const adc: u4 = 0b1010;
    pub const sbc: u4 = 0b1011;
    pub const sub: u4 = 0b1101;
    pub const rsb: u4 = 0b1110;
};

pub const group: op.Group = .{ .name = "imm_arith", .decode = decode };

fn decode(instr: Instr) ?op.Exec {
    const f = Fields.of(instr) orelse return null;
    switch (f.opcode) {
        opcodes.add, opcodes.adc, opcodes.sbc, opcodes.sub, opcodes.rsb => {},
        else => return null,
    }
    if (!thumb_imm.valid(instr)) return null;
    return if (allowed(f)) exec else null;
}

fn allowed(f: Fields) bool {
    const add_sub = f.opcode == opcodes.add or f.opcode == opcodes.sub;
    if (add_sub and f.rd == 15 and f.s) return f.rn != 15;
    if (add_sub and f.rn == 13) return f.rd != 15;
    return !f.rdIsSpOrPc() and !f.rnIsSpOrPc();
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = Fields.of(instr).?;
    const imm = thumb_imm.expandC(thumb_imm.imm12(instr), false).?.result;
    const n = cpu.regs.get(f.rn);
    const carry = flags.carry(&cpu.regs);
    const sum = switch (f.opcode) {
        opcodes.add => flags.addWithCarry(n, imm, false),
        opcodes.adc => flags.addWithCarry(n, imm, carry),
        opcodes.sbc => flags.addWithCarry(n, ~imm, carry),
        opcodes.sub => flags.addWithCarry(n, ~imm, true),
        else => flags.addWithCarry(~n, imm, true),
    };
    if (f.rd != 15) cpu.regs.set(f.rd, sum.result);
    if (f.s) flags.setNZCV(&cpu.regs, sum);
}
