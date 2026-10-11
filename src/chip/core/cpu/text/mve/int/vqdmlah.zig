//! Text for MVE doubling multiply-accumulate by scalar, per DDI0553 B5.
const Instr = @import("../../../instr.zig").Instr;
const ops = @import("../../../ops/mve/int/vqdmlah.zig");
const text = @import("../../text.zig");

const sizes = [_][]const u8{ "8", "16", "32" };

pub fn print(instr: Instr, out: *text.Text) void {
    printPredicated(instr, out, "");
}

pub fn printPredicated(instr: Instr, out: *text.Text, suffix: []const u8) void {
    const form = ops.formOf(instr) orelse return;
    const mnemonic: []const u8 = if (form.scalar_addend) (if (form.round) "vqrdmlash" else "vqdmlash") else if (form.round) "vqrdmlah" else "vqdmlah";
    const qda: u3 = @intCast(instr.hw2 >> 13);
    const qn: u3 = @intCast(instr.hw1 >> 1 & 7);
    const rm = text.names[instr.hw2 & 15];
    out.put("{s}{s}.s{s} q{d}, q{d}, {s}", .{ mnemonic, suffix, sizes[(instr.hw1 >> 4) & 3], qda, qn, rm });
}
