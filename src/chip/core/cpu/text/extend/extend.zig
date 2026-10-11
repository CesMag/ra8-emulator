//! Text for the extend group: SXTH, SXTB, UXTH and UXTB, 16-bit.
const Instr = @import("../../instr.zig").Instr;
const text = @import("../text.zig");

const mnemonics = [4][]const u8{ "sxth", "sxtb", "uxth", "uxtb" };

pub fn print(instr: Instr, out: *text.Text) void {
    out.regs2(mnemonics[(instr.hw1 >> 6) & 0x3], text.low(instr.hw1, 0), text.low(instr.hw1, 3));
}
