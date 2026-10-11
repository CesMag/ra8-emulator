//! Text for vector saturating and pairwise integer operations, per DDI0553 B5.
const Instr = @import("../../../instr.zig").Instr;
const ops = @import("../../../ops/mve/int/pair.zig");
const mve_int = @import("../../../ops/mve/int/int.zig");
const text = @import("../../text.zig");

const sizes = [_][]const u8{ "8", "16", "32" };

fn mnemonic(instr: Instr) []const u8 {
    const tail = instr.hw2 & mve_int.encodings.hw2_mask;
    if (tail == ops.encodings.vqadd) return "vqadd";
    if (tail == ops.encodings.vqsub) return "vqsub";
    if (tail == ops.encodings.vhadd) return "vhadd";
    if (tail == ops.encodings.vrhadd) return "vrhadd";
    if (tail == ops.encodings.vhsub) return "vhsub";
    if (tail == ops.encodings.vmax) return "vmax";
    if (tail == ops.encodings.vmin) return "vmin";
    return "vabd";
}

pub fn print(instr: Instr, out: *text.Text) void {
    printPredicated(instr, out, "");
}

pub fn printPredicated(instr: Instr, out: *text.Text, suffix: []const u8) void {
    const r = mve_int.regs(instr);
    const size = (instr.hw1 >> 4) & 3;
    const signedness = if (instr.hw1 >> 12 & 1 == 1) "u" else "s";
    out.put("{s}{s}.{s}{s} q{d}, q{d}, q{d}", .{ mnemonic(instr), suffix, signedness, sizes[size], r[0], r[1], r[2] });
}
