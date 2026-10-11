//! Text for MVE floating point scalar arithmetic, per DDI0553 B5.
const Instr = @import("../../../instr.zig").Instr;
const ops = @import("../../../ops/mve/float/scalar.zig");
const text = @import("../../text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    printPredicated(instr, out, "");
}

pub fn printPredicated(instr: Instr, out: *text.Text, suffix: []const u8) void {
    const kind = ops.kindOf(instr) orelse return;
    const mnemonic: []const u8 = switch (kind) {
        .vadd => "vadd",
        .vsub => "vsub",
        .vmul => "vmul",
        .vfma => "vfma",
        .vfmas => "vfmas",
    };
    const width = if (instr.hw1 >> 12 & 1 == 1) "f16" else "f32";
    const qd: u3 = @intCast(instr.hw2 >> 13);
    const qn: u3 = @intCast(instr.hw1 >> 1 & 7);
    const rm = text.names[instr.hw2 & 15];
    out.put("{s}{s}.{s} q{d}, q{d}, {s}", .{ mnemonic, suffix, width, qd, qn, rm });
}
