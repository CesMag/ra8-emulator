//! Text for MVE multiply high operations, per DDI0553 B5.
const Instr = @import("../../../instr.zig").Instr;
const mve_int = @import("../../../ops/mve/int/int.zig");
const mulh = @import("../../../ops/mve/int/mulh.zig");
const text = @import("../../text.zig");

const sizes = [_][]const u8{ "8", "16", "32" };

pub fn print(instr: Instr, out: *text.Text) void {
    printPredicated(instr, out, "");
}

pub fn printPredicated(instr: Instr, out: *text.Text, suffix: []const u8) void {
    const tail = instr.hw2 & mve_int.encodings.hw2_mask;
    const doubled = tail == mulh.encodings.vqdmulh;
    const rounded = if (doubled) instr.hw1 >> 12 & 1 == 1 else tail == mulh.encodings.vrmulh;
    const unsigned = !doubled and instr.hw1 >> 12 & 1 == 1;
    const mnemonic: []const u8 = if (doubled) (if (rounded) "vqrdmulh" else "vqdmulh") else if (rounded) "vrmulh" else "vmulh";
    const sign = if (doubled) "s" else if (unsigned) "u" else "s";
    const size = sizes[(instr.hw1 >> 4) & 3];
    const r = mve_int.regs(instr);
    out.put("{s}{s}.{s}{s} q{d}, q{d}, q{d}", .{ mnemonic, suffix, sign, size, r[0], r[1], r[2] });
}
