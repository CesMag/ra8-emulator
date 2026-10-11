//! Text for MVE integer vector-by-scalar arithmetic, per DDI0553 B5.
const Instr = @import("../../../instr.zig").Instr;
const ops = @import("../../../ops/mve/int/scalar.zig");
const text = @import("../../text.zig");

const sizes = [_][]const u8{ "8", "16", "32" };

pub fn print(instr: Instr, out: *text.Text) void {
    printPredicated(instr, out, "");
}

pub fn printPredicated(instr: Instr, out: *text.Text, suffix: []const u8) void {
    const kind = ops.kindOf(instr) orelse return;
    const mnemonic: []const u8 = switch (kind) {
        .vadd => "vadd",
        .vsub => "vsub",
        .vmul => "vmul",
        .vbrsr => "vbrsr",
        .vqdmulh => "vqdmulh",
        .vqrdmulh => "vqrdmulh",
        .vqadd => "vqadd",
        .vqsub => "vqsub",
        .vhadd => "vhadd",
        .vhsub => "vhsub",
    };
    const suffix_type = switch (kind) {
        .vadd, .vsub, .vmul => "i",
        .vbrsr => "u",
        .vqdmulh, .vqrdmulh => "s",
        .vqadd, .vqsub, .vhadd, .vhsub => if (instr.hw1 >> 12 & 1 == 1) "u" else "s",
    };
    const qd: u3 = @intCast(instr.hw2 >> 13);
    const qn: u3 = @intCast(instr.hw1 >> 1 & 7);
    const rm = text.names[instr.hw2 & 15];
    out.put("{s}{s}.{s}{s} q{d}, q{d}, {s}", .{ mnemonic, suffix, suffix_type, sizes[(instr.hw1 >> 4) & 3], qd, qn, rm });
}
