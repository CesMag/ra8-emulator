//! The logical 32-bit data processing (modified immediate) forms: AND, BIC,
//! ORR, ORN, EOR, with MOV and MVN (ORR and ORN with Rn of PC) and TST and
//! TEQ (AND and EOR with Rd of PC and S set). With S set they write N and Z,
//! and C from the immediate's expansion; V is left alone.
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
    pub const and_: u4 = 0b0000;
    pub const bic: u4 = 0b0001;
    pub const orr: u4 = 0b0010;
    pub const orn: u4 = 0b0011;
    pub const eor: u4 = 0b0100;
};

pub const group: op.Group = .{ .name = "imm_logic", .decode = decode };

fn decode(instr: Instr) ?op.Exec {
    const f = Fields.of(instr) orelse return null;
    if (f.opcode > opcodes.eor or !thumb_imm.valid(instr)) return null;
    return if (allowed(f)) exec else null;
}

fn allowed(f: Fields) bool {
    const moves = f.opcode == opcodes.orr or f.opcode == opcodes.orn;
    if (moves and f.rn == 15) return !f.rdIsSpOrPc();
    const tests = f.opcode == opcodes.and_ or f.opcode == opcodes.eor;
    if (tests and f.rd == 15 and f.s) return !f.rnIsSpOrPc();
    return !f.rdIsSpOrPc() and !f.rnIsSpOrPc();
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = Fields.of(instr).?;
    const imm = thumb_imm.expandC(thumb_imm.imm12(instr), flags.carry(&cpu.regs)).?;
    const n: u32 = if (f.rn == 15) 0 else cpu.regs.get(f.rn);
    const result = switch (f.opcode) {
        opcodes.and_ => n & imm.result,
        opcodes.bic => n & ~imm.result,
        opcodes.orr => n | imm.result,
        opcodes.orn => n | ~imm.result,
        else => n ^ imm.result,
    };
    if (f.rd != 15) cpu.regs.set(f.rd, result);
    if (f.s) flags.setNZC(&cpu.regs, result, imm.carry);
}
