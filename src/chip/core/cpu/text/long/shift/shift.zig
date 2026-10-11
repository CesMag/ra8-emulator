//! Text for the long_shift group (Armv8.1-M), in Arm ARM syntax: `lsll
//! rdalo, rdahi, #imm`, and LSRL and ASRL the same way. The fields come from
//! the executor's own `fields`, so text and execution cannot disagree.
//! We read these as ORRS with PC.
const Instr = @import("../../../instr.zig").Instr;
const ops = @import("../../../ops/long/shift/shift.zig");
const text = @import("../../text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    const f = ops.fields(instr) orelse return;
    out.put("{s} {s}, {s}, ", .{ @tagName(f.kind), text.names[f.lo], text.names[f.hi] });
    out.imm(f.amount);
}
