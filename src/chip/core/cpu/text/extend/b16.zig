//! Text for the extend_b16 group: SXTB16/UXTB16 and SXTAB16/UXTAB16.
//! These have no 16-bit forms, so we print no .w; a nonzero rotation
//! prints as ", ror #8|16|24" in decimal.
const Instr = @import("../../instr.zig").Instr;
const text = @import("../text.zig");
const Fields = @import("../../ops/extend/b16.zig").Fields;

pub fn print(instr: Instr, out: *text.Text) void {
    const f = Fields.of(instr).?;
    const s = if (f.signed) "s" else "u";
    if (f.rn == 15) {
        out.put("{s}xtb16 {s}, {s}", .{ s, text.names[f.rd], text.names[f.rm] });
    } else {
        out.put("{s}xtab16 {s}, {s}, {s}", .{ s, text.names[f.rd], text.names[f.rn], text.names[f.rm] });
    }
    if (f.rotation != 0) out.put(", ror #{d}", .{f.rotation});
}
