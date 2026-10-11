//! Text for the long_shift_sat group (Armv8.1-M), in Arm ARM syntax: `uqshl
//! rda, #imm` (and URSHR, SRSHR, SQSHL), or `uqrshl rda, rm` (and SQRSHR),
//! from the executor's own `fields`.
const Instr = @import("../../../instr.zig").Instr;
const ops = @import("../../../ops/long/shift/sat.zig");
const text = @import("../../text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    const f = ops.fields(instr) orelse return;
    out.put("{s} {s}, ", .{ @tagName(f.kind), text.names[f.rda] });
    if (f.rm) |rm| return out.reg(rm);
    out.imm(f.amount);
}
