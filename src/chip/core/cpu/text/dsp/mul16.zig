//! Text for the dsp.mul16 group: smul<x><y>/smla<x><y> and smulw<y>/smlaw<y>.
//! x and y are b or t for the bottom or top halfword; Ra = PC selects the
//! smul forms, which drop the accumulator operand.
const Instr = @import("../../instr.zig").Instr;
const text = @import("../text.zig");
const mul16 = @import("../../ops/dsp/mul16.zig");

fn half(top: bool) []const u8 {
    return if (top) "t" else "b";
}

pub fn print(instr: Instr, out: *text.Text) void {
    const f = mul16.Fields.of(instr).?;
    const acc = f.ra != mul16.encodings.no_ra;
    const base = if (acc) "smla" else "smul";
    const x = if (f.wide) "w" else half(f.top_n);
    out.put("{s}{s}{s} {s}, {s}, {s}", .{ base, x, half(f.top_m), text.names[f.rd], text.names[f.rn], text.names[f.rm] });
    if (acc) out.put(", {s}", .{text.names[f.ra]});
}
