//! Text for the two-lane VMOV forms, per DDI0553 B5.4 and C2.4.528.
const Instr = @import("../../../instr.zig").Instr;
const ops = @import("../../../ops/mve/lane/pair.zig");
const text = @import("../../text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    const f = ops.fields(instr);
    if (f.to_vector) {
        out.put("vmov q{d}[{d}], q{d}[{d}], {s}, {s}", .{ f.qd, f.high, f.qd, f.low, text.names[f.rt], text.names[f.rt2] });
    } else {
        out.put("vmov {s}, {s}, q{d}[{d}], q{d}[{d}]", .{ text.names[f.rt], text.names[f.rt2], f.qd, f.high, f.qd, f.low });
    }
}
