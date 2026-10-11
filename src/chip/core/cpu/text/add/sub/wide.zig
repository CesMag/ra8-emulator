//! Text for the add.sub.wide group: ADDW and SUBW with a plain 12-bit
//! immediate. We keep the ADDW/SUBW spelling for Rn of PC too rather
//! than print ADR.
const Instr = @import("../../../instr.zig").Instr;
const text = @import("../../text.zig");
const Fields = @import("../../../ops/add/sub/wide.zig").Fields;

pub fn print(instr: Instr, out: *text.Text) void {
    const f = Fields.of(instr).?;
    out.put("{s} {s}, {s}, ", .{ if (f.sub) "subw" else "addw", text.names[f.rd], text.names[f.rn] });
    out.imm(f.imm12);
}
