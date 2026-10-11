//! Text for MVE 64-bit register-offset gather/scatter, per DDI0553 B5.
const Instr = @import("../../instr.zig").Instr;
const ops = @import("../../ops/mve/gather64.zig");
const text = @import("../text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    printPredicated(instr, out, "");
}

pub fn printPredicated(instr: Instr, out: *text.Text, suffix: []const u8) void {
    const load = instr.hw1 >> 4 & 1 == 1;
    const qd: u3 = @intCast(instr.hw2 >> 13 & 7);
    const qm: u3 = @intCast(instr.hw2 >> 1 & 7);
    const rn = text.names[instr.hw1 & 15];
    const root = if (load) "vldrd" else "vstrd";
    const dtype = if (load) ".u64" else ".64";
    const os = if (instr.hw2 & 1 == 1) ", uxtw #3" else "";
    _ = ops.group;
    out.put("{s}{s}{s} q{d}, [{s}, q{d}{s}]", .{ root, suffix, dtype, qd, rn, qm, os });
}
