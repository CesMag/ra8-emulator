//! Text for MVE F16/F32 narrowing and widening, per DDI0553 C2.4.327.
const Instr = @import("../../../../instr.zig").Instr;
const ops = @import("../../../../ops/mve/float/cvt/half.zig");
const text = @import("../../../text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    printPredicated(instr, out, "");
}

pub fn printPredicated(instr: Instr, out: *text.Text, suffix: []const u8) void {
    const f = ops.fields(instr) orelse return;
    const mnemonic = if (f.top) "vcvtt" else "vcvtb";
    const types = if (f.widen) ".f32.f16" else ".f16.f32";
    out.put("{s}{s}{s} q{d}, q{d}", .{ mnemonic, suffix, types, f.qd, f.qm });
}
