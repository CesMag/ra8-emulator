//! Text for MVE floating point rounding operations, per DDI0553 B5.
const Instr = @import("../../../instr.zig").Instr;
const ops = @import("../../../ops/mve/float/rint.zig");
const text = @import("../../text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    printPredicated(instr, out, "");
}

pub fn printPredicated(instr: Instr, out: *text.Text, suffix: []const u8) void {
    const f = ops.fields(instr) orelse return;
    const rounding = switch (f.kind) {
        .n => "n",
        .x => "x",
        .a => "a",
        .z => "z",
        .m => "m",
        .p => "p",
    };
    const width = if (f.size == .half) "f16" else "f32";
    out.put("vrint{s}{s}.{s} q{d}, q{d}", .{ rounding, suffix, width, f.qd, f.qm });
}
