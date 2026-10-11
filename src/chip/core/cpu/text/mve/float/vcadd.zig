//! Text for MVE complex add, per DDI0553 B5.
const Instr = @import("../../../instr.zig").Instr;
const mve_int = @import("../../../ops/mve/int/int.zig");
const ops = @import("../../../ops/mve/float/vcadd.zig");
const text = @import("../../text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    printPredicated(instr, out, "");
}

pub fn printPredicated(instr: Instr, out: *text.Text, suffix: []const u8) void {
    if (!ops.claims(instr)) return;
    const r = mve_int.regs(instr);
    const width = if (instr.hw1 >> 4 & 1 == 1) "f32" else "f16";
    const rotation: u32 = if (instr.hw1 >> 8 & 1 == 1) 270 else 90;
    out.put("vcadd{s}.{s} q{d}, q{d}, q{d}, #{d}", .{ suffix, width, r[0], r[1], r[2], rotation });
}
