//! Text for MVE vector-base immediate gather/scatter, per DDI0553 B5.
const Instr = @import("../../../instr.zig").Instr;
const ops = @import("../../../ops/mve/gather/imm.zig");
const text = @import("../../text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    printPredicated(instr, out, "");
}

pub fn printPredicated(instr: Instr, out: *text.Text, suffix: []const u8) void {
    const load = instr.hw1 >> 4 & 1 == 1;
    const writeback = instr.hw1 >> 5 & 1 == 1;
    const double = instr.hw2 >> 8 & 1 == 1;
    const qm: u3 = @intCast(instr.hw1 >> 1 & 7);
    const qd: u3 = @intCast(instr.hw2 >> 13 & 7);
    const scale: i32 = if (double) 8 else 4;
    const imm: i32 = @as(i32, @intCast(instr.hw2 & 0x7f)) * scale;
    const add = instr.hw1 >> 7 & 1 == 1;
    const sign = if (add) "+" else "-";
    const letter = if (double) "d" else "w";
    const root = if (load) "vldr" else "vstr";
    const dtype = if (load) (if (double) ".u64" else ".u32") else if (double) ".64" else ".32";
    const bang = if (writeback) "!" else "";
    _ = ops.group;
    out.put("{s}{s}{s}{s} q{d}, [q{d}, #{s}{d}]{s}", .{ root, letter, suffix, dtype, qd, qm, sign, imm, bang });
}
