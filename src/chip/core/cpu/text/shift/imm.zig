//! Text for the shift_imm group: LSLS/LSRS/ASRS by an immediate, and LSL #0
//! as MOVS.
const Instr = @import("../../instr.zig").Instr;
const text = @import("../text.zig");

const mnemonics = [3][]const u8{ "lsls", "lsrs", "asrs" };

pub fn print(instr: Instr, out: *text.Text) void {
    const kind = (instr.hw1 >> 11) & 0x3;
    const imm5: u32 = (instr.hw1 >> 6) & 0x1F;
    const rm = text.low(instr.hw1, 3);
    const rd = text.low(instr.hw1, 0);
    if (kind == 0 and imm5 == 0) return out.regs2("movs", rd, rm);
    out.regs2(mnemonics[kind], rd, rm);
    out.put(", ", .{});
    out.imm(if (imm5 == 0) 32 else imm5);
}
