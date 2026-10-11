//! Text for the imm.logic group: AND, BIC, ORR, ORN and EOR with a modified
//! immediate, and their aliases TST and TEQ (Rd of PC with S set) and MOV
//! and MVN (Rn of PC). We write `.w` only on TST, TEQ and MOV, the
//! forms that also have a 16-bit encoding. We print the immediate of
//! TST, TEQ, MOV and ORN as signed (`#-1`), the rest as unsigned.
const Instr = @import("../../instr.zig").Instr;
const text = @import("../text.zig");
const thumb_imm = @import("../../thumb_imm.zig");
const Fields = @import("../../ops/imm/fields.zig").Fields;
const opcodes = @import("../../ops/imm/logic.zig").opcodes;

const mnemonics = [5][]const u8{ "and", "bic", "orr", "orn", "eor" };

pub fn print(instr: Instr, out: *text.Text) void {
    const f = Fields.of(instr).?;
    const s: []const u8 = if (f.s) "s" else "";
    const tests = f.opcode == opcodes.and_ or f.opcode == opcodes.eor;
    if (tests and f.rd == 15 and f.s) {
        const mnemonic: []const u8 = if (f.opcode == opcodes.and_) "tst" else "teq";
        out.put("{s}.w {s}, ", .{ mnemonic, text.names[f.rn] });
        return out.signedImm(value(instr));
    }
    if (f.rn == 15 and f.opcode == opcodes.orr) {
        out.put("mov{s}.w {s}, ", .{ s, text.names[f.rd] });
        return out.signedImm(value(instr));
    }
    if (f.rn == 15 and f.opcode == opcodes.orn) {
        out.put("mvn{s} {s}, ", .{ s, text.names[f.rd] });
        return out.imm(value(instr));
    }
    out.put("{s}{s} {s}, {s}, ", .{ mnemonics[f.opcode], s, text.names[f.rd], text.names[f.rn] });
    // We read ORN's immediate as signed and the others as unsigned.
    if (f.opcode == opcodes.orn) out.signedImm(value(instr)) else out.imm(value(instr));
}

/// The expanded immediate; decode has already refused the null patterns.
pub fn value(instr: Instr) u32 {
    return thumb_imm.expandC(thumb_imm.imm12(instr), false).?.result;
}
