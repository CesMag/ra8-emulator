//! Text for MVE scalar maxnum/minnum reductions, per DDI0553 B5.
const Instr = @import("../../../instr.zig").Instr;
const ops = @import("../../../ops/mve/float/maxnmv.zig");
const text = @import("../../text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    printPredicated(instr, out, "");
}

pub fn printPredicated(instr: Instr, out: *text.Text, suffix: []const u8) void {
    const f = ops.fields(instr) orelse return;
    const root = if (f.abs) (if (f.which == .max) "vmaxnmav" else "vminnmav") else if (f.which == .max) "vmaxnmv" else "vminnmv";
    const width = if (f.size == .half) "f16" else "f32";
    out.put("{s}{s}.{s} {s}, q{d}", .{ root, suffix, width, text.names[f.rda], f.qm });
}
