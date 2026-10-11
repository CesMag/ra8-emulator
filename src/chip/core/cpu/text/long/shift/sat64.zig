//! Text for the long_shift_sat64 group (Armv8.1-M), in Arm ARM syntax:
//! `uqshll rdalo, rdahi, #imm` (and URSHRL, SRSHRL, SQSHLL), or `uqrshll
//! rdalo, rdahi, #saturate, rm` (and SQRSHRL) with the saturation width, 64
//! or 48, as an immediate. Fields come from the executor's own `fields`.
const Instr = @import("../../../instr.zig").Instr;
const ops = @import("../../../ops/long/shift/sat64.zig");
const text = @import("../../text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    const f = ops.fields(instr) orelse return;
    out.put("{s} {s}, {s}, ", .{ @tagName(f.kind), text.names[f.lo], text.names[f.hi] });
    if (f.rm) |rm| {
        out.imm(f.bits);
        return out.put(", {s}", .{text.names[rm]});
    }
    out.imm(f.amount);
}
