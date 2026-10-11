//! Text for the dsp.long_mul group: smlal<x><y>, and smlald/smlsld with an
//! x suffix when Rm's halves are swapped. The operands are always
//! RdLo, RdHi, Rn, Rm.
const Instr = @import("../../instr.zig").Instr;
const text = @import("../text.zig");
const long = @import("../../ops/dsp/long_mul.zig");

fn half(top: bool) []const u8 {
    return if (top) "t" else "b";
}

pub fn print(instr: Instr, out: *text.Text) void {
    const f = long.Fields.of(instr).?;
    switch (f.form) {
        .halves => |h| out.put("smlal{s}{s}", .{ half(h.n_top), half(h.m_top) }),
        .dual => |d| out.put("{s}{s}", .{
            if (d.subtract) "smlsld" else "smlald",
            if (d.swap) "x" else "",
        }),
    }
    out.put(" {s}, {s}, {s}, {s}", .{ text.names[f.rd_lo], text.names[f.rd_hi], text.names[f.rn], text.names[f.rm] });
}
