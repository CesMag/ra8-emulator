//! Text for MVE VABS/VNEG, per DDI0553 B5.
const Instr = @import("../../../instr.zig").Instr;
const ops = @import("../../../ops/mve/float/unary.zig");
const text = @import("../../text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    printPredicated(instr, out, "");
}

pub fn printPredicated(instr: Instr, out: *text.Text, suffix: []const u8) void {
    const f = ops.fields(instr) orelse return;
    const mnemonic = if (f.op == .abs) "vabs" else "vneg";
    const width = if (f.size == .half) "f16" else "f32";
    out.put("{s}{s}.{s} q{d}, q{d}", .{ mnemonic, suffix, width, f.qd, f.qm });
}
