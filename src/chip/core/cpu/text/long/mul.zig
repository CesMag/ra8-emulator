//! Text for the long_mul group: smull, umull, smlal and umlal
//! RdLo, RdHi, Rn, Rm.
const Instr = @import("../../instr.zig").Instr;
const text = @import("../text.zig");
const Fields = @import("../../ops/long/mul.zig").Fields;

pub fn print(instr: Instr, out: *text.Text) void {
    const f = Fields.of(instr).?;
    const sign = if (f.signed) "s" else "u";
    const kind = if (f.accumulate) "mlal" else "mull";
    out.put("{s}{s} {s}, {s}, {s}, {s}", .{ sign, kind, text.names[f.rd_lo], text.names[f.rd_hi], text.names[f.rn], text.names[f.rm] });
}
