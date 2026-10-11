//! Text for the dsp_dual group: SMLAD, SMLSD (Rd, Rn, Rm, Ra) and SMUAD, SMUSD
//! (Rd, Rn, Rm when Ra is 1111), each with an x suffix when Rm's halves swap.
const Instr = @import("../../instr.zig").Instr;
const text = @import("../text.zig");
const dsp_dual = @import("../../ops/dsp/dual.zig");

/// Mnemonic by [subtract][swap][multiply only].
const mnemonics = [2][2][2][]const u8{
    .{ .{ "smlad", "smuad" }, .{ "smladx", "smuadx" } },
    .{ .{ "smlsd", "smusd" }, .{ "smlsdx", "smusdx" } },
};

pub fn print(instr: Instr, out: *text.Text) void {
    const f = dsp_dual.Fields.of(instr) orelse return;
    const mul_only = f.ra == dsp_dual.encodings.no_ra;
    const name = mnemonics[@intFromBool(f.subtract)][@intFromBool(f.swap)][@intFromBool(mul_only)];
    out.regs3(name, f.rd, f.rn, f.rm);
    if (!mul_only) out.put(", {s}", .{text.names[f.ra]});
}
