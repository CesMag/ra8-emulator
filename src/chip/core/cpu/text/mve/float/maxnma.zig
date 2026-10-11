//! Text for MVE absolute maxnum/minnum accumulation, per DDI0553 B5.
const Instr = @import("../../../instr.zig").Instr;
const ops = @import("../../../ops/mve/float/maxnma.zig");
const text = @import("../../text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    printPredicated(instr, out, "");
}

pub fn printPredicated(instr: Instr, out: *text.Text, suffix: []const u8) void {
    const op = ops.which(instr) orelse return;
    const mnemonic = if (op == .min) "vminnma" else "vmaxnma";
    const width = if (instr.hw1 >> 12 & 1 == 1) "f16" else "f32";
    const qd: u3 = @intCast(instr.hw2 >> 13 & 7);
    const qm: u3 = @intCast(instr.hw2 >> 1 & 7);
    out.put("{s}{s}.{s} q{d}, q{d}", .{ mnemonic, suffix, width, qd, qm });
}
