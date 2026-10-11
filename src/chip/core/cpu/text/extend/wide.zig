//! Text for the extend_wide group: SXTH/UXTH/SXTB/UXTB.W and the SXTAH,
//! UXTAH, SXTAB and UXTAB accumulating forms. We put .w only on the
//! plain forms (they have 16-bit encodings) and prints a nonzero rotation
//! as ", ror #8|16|24" in decimal.
const Instr = @import("../../instr.zig").Instr;
const text = @import("../text.zig");
const Fields = @import("../../ops/extend/wide.zig").Fields;

pub fn print(instr: Instr, out: *text.Text) void {
    const f = Fields.of(instr).?;
    const name = @tagName(f.kind);
    if (f.rn == 15) {
        out.put("{s}.w {s}, {s}", .{ name, text.names[f.rd], text.names[f.rm] });
    } else {
        out.put("{s}a{s} {s}, {s}, {s}", .{ name[0..3], name[3..], text.names[f.rd], text.names[f.rn], text.names[f.rm] });
    }
    if (f.rotation != 0) out.put(", ror #{d}", .{f.rotation});
}
