//! Text for the ldst.reg group: the eight loads and stores with a register
//! offset, `op rt, [rn, rm]`.
const Instr = @import("../../../instr.zig").Instr;
const text = @import("../../text.zig");

const mnemonics = [8][]const u8{ "str", "strh", "strb", "ldrsb", "ldr", "ldrh", "ldrb", "ldrsh" };

pub fn print(instr: Instr, out: *text.Text) void {
    const hw1 = instr.hw1;
    const rt = text.names[text.low(hw1, 0)];
    const rn = text.names[text.low(hw1, 3)];
    const rm = text.names[text.low(hw1, 6)];
    out.put("{s} {s}, [{s}, {s}]", .{ mnemonics[(hw1 >> 9) & 0x7], rt, rn, rm });
}
