//! Text for MVE float/integer conversion and named rounding, per DDI0553 C2.4.326.
const Instr = @import("../../../../instr.zig").Instr;
const ops = @import("../../../../ops/mve/float/cvt/int.zig");
const text = @import("../../../text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    printPredicated(instr, out, "");
}

pub fn printPredicated(instr: Instr, out: *text.Text, suffix: []const u8) void {
    const f = ops.fields(instr) orelse return;
    const float_type = if (f.size == .word) "f32" else "f16";
    const int_type = if (f.unsigned) (if (f.size == .word) "u32" else "u16") else if (f.size == .word) "s32" else "s16";
    const rounding = f.rounding;
    const mnemonic: []const u8 = if (rounding == null or rounding.? == .zero) "vcvt" else switch (rounding.?) {
        .ties_away => "vcvta",
        .nearest => "vcvtn",
        .plus_inf => "vcvtp",
        .minus_inf => "vcvtm",
        .zero => "vcvt",
    };
    const dst = if (rounding == null) float_type else int_type;
    const src = if (rounding == null) int_type else float_type;
    out.put("{s}{s}.{s}.{s} q{d}, q{d}", .{ mnemonic, suffix, dst, src, f.qd, f.qm });
}
