//! Text for the shift_reg group: LSL, LSR, ASR and ROR by a register, the
//! 32-bit forms. Each has a 16-bit twin, so we write `.w` on all.
const Instr = @import("../../instr.zig").Instr;
const text = @import("../text.zig");
const Fields = @import("../../ops/shift/reg.zig").Fields;

const kinds = [4][]const u8{ "lsl", "lsr", "asr", "ror" };

pub fn print(instr: Instr, out: *text.Text) void {
    const f = Fields.of(instr).?;
    const s: []const u8 = if (f.s) "s" else "";
    out.put("{s}{s}.w {s}, {s}, {s}", .{ kinds[@backingInt(f.kind)], s, text.names[f.rd], text.names[f.rn], text.names[f.rm] });
}
