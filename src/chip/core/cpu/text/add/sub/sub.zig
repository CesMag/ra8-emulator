//! Text for the add.sub group: ADDS/SUBS with three operands, and the
//! MOVS/CMP/ADDS/SUBS immediate-8 forms.
const Instr = @import("../../../instr.zig").Instr;
const text = @import("../../text.zig");

const imm8_mnemonics = [4][]const u8{ "movs", "cmp", "adds", "subs" };

pub fn print(instr: Instr, out: *text.Text) void {
    const hw1 = instr.hw1;
    if (hw1 & 0xE000 == 0) return threeOperand(hw1, out);
    out.put("{s} ", .{imm8_mnemonics[(hw1 >> 11) & 0x3]});
    out.reg(text.low(hw1, 8));
    out.put(", ", .{});
    out.imm(hw1 & 0xFF);
}

fn threeOperand(hw1: u16, out: *text.Text) void {
    const mnemonic: []const u8 = if (hw1 & 0x0200 != 0) "subs" else "adds";
    const field = text.low(hw1, 6);
    if (hw1 & 0x0400 == 0) return out.regs3(mnemonic, text.low(hw1, 0), text.low(hw1, 3), field);
    out.regs2(mnemonic, text.low(hw1, 0), text.low(hw1, 3));
    out.put(", ", .{});
    out.imm(field);
}
