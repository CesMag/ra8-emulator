//! Text for the ldm_stm group: STM always writes back; LDM writes back only
//! when the base is not in the list.
const Instr = @import("../../../instr.zig").Instr;
const text = @import("../../text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    const hw1 = instr.hw1;
    const rn = text.low(hw1, 8);
    const load = hw1 & 0x0800 != 0;
    const wback = !load or hw1 & (@as(u16, 1) << rn) == 0;
    out.put("{s} {s}{s}, ", .{ if (load) "ldm" else "stm", text.names[rn], if (wback) "!" else "" });
    out.list(hw1 & 0xFF);
}
