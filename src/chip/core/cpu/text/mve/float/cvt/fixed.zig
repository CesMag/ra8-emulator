//! Text for MVE fixed point and floating point conversion, per DDI0553 C2.4.325.
const Instr = @import("../../../../instr.zig").Instr;
const ops = @import("../../../../ops/mve/float/cvt/fixed.zig");
const text = @import("../../../text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    printPredicated(instr, out, "");
}

pub fn printPredicated(instr: Instr, out: *text.Text, suffix: []const u8) void {
    const f = ops.fields(instr) orelse return;
    const float_type = if (f.size == .word) "f32" else "f16";
    const int_type = if (f.unsigned) (if (f.size == .word) "u32" else "u16") else if (f.size == .word) "s32" else "s16";
    const dst = if (f.to_fixed) int_type else float_type;
    const src = if (f.to_fixed) float_type else int_type;
    out.put("vcvt{s}.{s}.{s} q{d}, q{d}, #{d}", .{ suffix, dst, src, f.qd, f.qm, f.fbits });
}
