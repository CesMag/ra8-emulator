//! Text for the ldr_literal_wide group: the 32-bit literal loads
//! `ldr{s}{b,h}.w rt, [pc, #imm]` in the spelling the parity digests pin. Every form
//! carries `.w` and keeps a zero offset (`[pc, #0]`). A subtracted offset is
//! always hex, zero included (`#-0x0`); an added one follows the usual
//! decimal-below-ten rule.
const Instr = @import("../../../instr.zig").Instr;
const text = @import("../../text.zig");
const ldr_literal_wide = @import("../../../ops/ldr/literal/wide.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    const f = ldr_literal_wide.form(instr) orelse return;
    out.put("ldr{s}{s}.w ", .{
        if (f.signed) "s" else "",
        switch (f.size) {
            1 => "b",
            2 => "h",
            else => "",
        },
    });
    out.reg(f.rt);
    const value: u32 = instr.hw2 & 0x0FFF;
    if (instr.hw1 & 0x0080 == 0) return out.put(", [pc, #-0x{x}]", .{value});
    out.put(", [pc, ", .{});
    out.imm(value);
    out.put("]", .{});
}
