//! Text for VMAXV, VMINV, VMAXAV and VMINAV, per DDI0553 B5.4.
const Instr = @import("../../instr.zig").Instr;
const ops = @import("../../ops/mve/vmaxv.zig");
const text = @import("../text.zig");

const sizes = [_][]const u8{ "8", "16", "32" };

pub fn print(instr: Instr, out: *text.Text) void {
    printPredicated(instr, out, "");
}

pub fn printPredicated(instr: Instr, out: *text.Text, suffix: []const u8) void {
    const f = ops.fieldsOf(instr) orelse return;
    const rda: u4 = @intCast(instr.hw2 >> 12);
    const qm: u3 = @intCast(instr.hw2 >> 1 & 7);
    const root = if (f.form.abs)
        (if (f.form.kind == .max) "vmaxav" else "vminav")
    else
        (if (f.form.kind == .max) "vmaxv" else "vminv");
    const sign = if (f.form.unsigned) "u" else "s";
    const width = sizes[@backingInt(f.size)];
    out.put("{s}{s}.{s}{s} {s}, q{d}", .{ root, suffix, sign, width, text.names[rda], qm });
}
