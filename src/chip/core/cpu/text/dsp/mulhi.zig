//! Text for the dsp_mulhi group: smmul, smmla and smmls, with an r suffix
//! when the rounding bit is set. Ra = PC on 0xFB50 is smmul, which drops
//! the accumulator operand.
const Instr = @import("../../instr.zig").Instr;
const text = @import("../text.zig");
const mulhi = @import("../../ops/dsp/mulhi.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    const f = mulhi.Fields.of(instr).?;
    const acc = f.subtract or f.ra != mulhi.encodings.no_ra;
    const name = if (f.subtract) "smmls" else if (acc) "smmla" else "smmul";
    const r = if (f.round) "r" else "";
    out.put("{s}{s} {s}, {s}, {s}", .{ name, r, text.names[f.rd], text.names[f.rn], text.names[f.rm] });
    if (acc) out.put(", {s}", .{text.names[f.ra]});
}
