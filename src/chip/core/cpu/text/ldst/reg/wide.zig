//! Text for the ldst_reg_wide group: the 32-bit register-offset loads and
//! stores, `ldr.w rt, [rn, rm]` or `[rn, rm, lsl #n]` in the spelling
//! the parity digests pin. Every form carries `.w`, and a zero shift is left out.
const Instr = @import("../../../instr.zig").Instr;
const text = @import("../../text.zig");
const Fields = @import("../../../ops/ldst/reg/wide.zig").Fields;

pub fn print(instr: Instr, out: *text.Text) void {
    const f = Fields.of(instr) orelse return;
    out.put("{s}{s}{s}.w ", .{
        if (f.load) "ldr" else "str",
        if (f.signed) "s" else "",
        switch (f.size) {
            1 => "b",
            2 => "h",
            else => "",
        },
    });
    out.reg(f.rt);
    out.put(", [", .{});
    out.reg(f.rn);
    out.put(", ", .{});
    out.reg(f.rm);
    if (f.shift != 0) out.put(", lsl #{d}", .{f.shift});
    out.put("]", .{});
}
