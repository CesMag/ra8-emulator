//! Text for the imm_arith group: ADD, ADC, SBC, SUB and RSB with a modified
//! immediate, and CMN and CMP (ADD and SUB with Rd of PC and S set).
//! We write `.w` on ADD, SUB, RSB, CMN and CMP, the forms that also
//! have a 16-bit encoding, and not on ADC or SBC.
const Instr = @import("../../instr.zig").Instr;
const text = @import("../text.zig");
const Fields = @import("../../ops/imm/fields.zig").Fields;
const opcodes = @import("../../ops/imm/arith.zig").opcodes;
const value = @import("logic.zig").value;

pub fn print(instr: Instr, out: *text.Text) void {
    const f = Fields.of(instr).?;
    const add_sub = f.opcode == opcodes.add or f.opcode == opcodes.sub;
    if (add_sub and f.rd == 15 and f.s) {
        const mnemonic: []const u8 = if (f.opcode == opcodes.add) "cmn" else "cmp";
        out.put("{s}.w {s}, ", .{ mnemonic, text.names[f.rn] });
    } else {
        const wide: []const u8 = if (add_sub or f.opcode == opcodes.rsb) ".w" else "";
        const s: []const u8 = if (f.s) "s" else "";
        out.put("{s}{s}{s} {s}, {s}, ", .{ mnemonicOf(f.opcode), s, wide, text.names[f.rd], text.names[f.rn] });
    }
    out.signedImm(value(instr));
}

fn mnemonicOf(opcode: u4) []const u8 {
    return switch (opcode) {
        opcodes.add => "add",
        opcodes.adc => "adc",
        opcodes.sbc => "sbc",
        opcodes.sub => "sub",
        else => "rsb",
    };
}
