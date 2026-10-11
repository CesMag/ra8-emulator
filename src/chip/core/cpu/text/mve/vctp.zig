//! Text for VCTP, per DDI0553 B5.5 and C2.4.444.
const Instr = @import("../../instr.zig").Instr;
const ops = @import("../../ops/mve/vctp.zig");
const text = @import("../text.zig");

const sizes = [4][]const u8{ "8", "16", "32", "64" };

pub fn print(instr: Instr, out: *text.Text) void {
    const f = ops.fields(instr) orelse return;
    out.put("vctp.{s} {s}", .{ sizes[f.size], text.names[f.rn] });
}
