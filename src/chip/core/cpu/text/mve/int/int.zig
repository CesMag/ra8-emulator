//! Text for vector VADD, VSUB and VMUL (T1), per DDI0553 B5.
const Instr = @import("../../../instr.zig").Instr;
const ops = @import("../../../ops/mve/int/int.zig");
const text = @import("../../text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    printPredicated(instr, out, "");
}

pub fn printPredicated(instr: Instr, out: *text.Text, suffix: []const u8) void {
    const size: u2 = @intCast(instr.hw1 >> 4 & 3);
    const lane = ([_][]const u8{ "i8", "i16", "i32", "" })[size];
    const r = ops.regs(instr);
    const unsigned = instr.hw1 >> 12 & 1 == 1;
    const tail = instr.hw2 & ops.encodings.hw2_mask;
    const mnemonic: []const u8 = if (tail == ops.encodings.mul_hw2) "vmul" else if (unsigned) "vsub" else "vadd";
    out.put("{s}{s}.{s} q{d}, q{d}, q{d}", .{ mnemonic, suffix, lane, r[0], r[1], r[2] });
}
