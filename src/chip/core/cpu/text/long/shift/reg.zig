//! Text for the long_shift_reg group (Armv8.1-M), in Arm ARM syntax: `lsll
//! rdalo, rdahi, rm` and `asrl rdalo, rdahi, rm`, from the executor's own
//! `fields`.
const Instr = @import("../../../instr.zig").Instr;
const ops = @import("../../../ops/long/shift/reg.zig");
const text = @import("../../text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    const f = ops.fields(instr) orelse return;
    out.put("{s} {s}, {s}, {s}", .{ @tagName(f.kind), text.names[f.lo], text.names[f.hi], text.names[f.rm] });
}
