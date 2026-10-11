//! Text for VDUP (T1), per DDI0553 B5.4.
const Instr = @import("../../instr.zig").Instr;
const ops = @import("../../ops/mve/vdup.zig");
const text = @import("../text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    printPredicated(instr, out, "");
}

pub fn printPredicated(instr: Instr, out: *text.Text, suffix: []const u8) void {
    const f = ops.sizeOf(instr) orelse return;
    const qd: u3 = @intCast(instr.hw1 >> 1 & 7);
    const rt: u4 = @intCast(instr.hw2 >> 12);
    const size = switch (f) {
        .word => "32",
        .half => "16",
        .byte => "8",
    };
    out.put("vdup{s}.{s} q{d}, {s}", .{ suffix, size, qd, text.names[rt] });
}
