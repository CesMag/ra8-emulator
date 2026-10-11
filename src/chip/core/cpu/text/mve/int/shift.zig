//! Text for MVE register controlled integer shifts, per DDI0553 B5.
const Instr = @import("../../../instr.zig").Instr;
const mve_int = @import("../../../ops/mve/int/int.zig");
const shift = @import("../../../ops/mve/int/shift.zig");
const text = @import("../../text.zig");

const sizes = [_][]const u8{ "8", "16", "32" };

pub fn print(instr: Instr, out: *text.Text) void {
    printPredicated(instr, out, "");
}

pub fn printPredicated(instr: Instr, out: *text.Text, suffix: []const u8) void {
    const tail = instr.hw2 & mve_int.encodings.hw2_mask;
    const round = tail & shift.encodings.round_bit != 0;
    const saturate = tail & shift.encodings.saturate_bit != 0;
    const mnemonic: []const u8 = if (saturate) (if (round) "vqrshl" else "vqshl") else if (round) "vrshl" else "vshl";
    const sign = if (instr.hw1 >> 12 & 1 == 1) "u" else "s";
    const size = sizes[(instr.hw1 >> 4) & 3];
    const r = mve_int.regs(instr);
    out.put("{s}{s}.{s}{s} q{d}, q{d}, q{d}", .{ mnemonic, suffix, sign, size, r[0], r[2], r[1] });
}
