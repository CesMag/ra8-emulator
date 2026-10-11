//! Text for MVE vector maxnum/minnum, per DDI0553 B5.
const Instr = @import("../../../instr.zig").Instr;
const ops = @import("../../../ops/mve/float/maxnm.zig");
const mve_int = @import("../../../ops/mve/int/int.zig");
const text = @import("../../text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    printPredicated(instr, out, "");
}

pub fn printPredicated(instr: Instr, out: *text.Text, suffix: []const u8) void {
    const op = ops.which(instr) orelse return;
    const mnemonic = if (op == .min) "vminnm" else "vmaxnm";
    const width = if (instr.hw1 >> 4 & 1 == 1) "f16" else "f32";
    const r = mve_int.regs(instr);
    out.put("{s}{s}.{s} q{d}, q{d}, q{d}", .{ mnemonic, suffix, width, r[0], r[1], r[2] });
}
