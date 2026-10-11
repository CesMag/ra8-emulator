//! Text for the ldst_wide group: the 32-bit single-register loads and
//! stores with an immediate offset, in the spelling the parity digests pin.
//!
//! The imm12 forms carry `.w` and drop a zero offset. The imm8 forms do
//! not: an offset form prints a subtracted offset in hex (`#-0x4`), a
//! pre-indexed form keeps a zero (`#0]!`), and a post-indexed form uses the
//! decimal-below-ten rule on both signs (`#-0`, `#-9`, `#-0xa`). The unprivileged
//! family adds `t` and drops a zero offset.
const Instr = @import("../../instr.zig").Instr;
const text = @import("../text.zig");
const ldst_wide = @import("../../ops/ldst/wide.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    const f = ldst_wide.form(instr) orelse return;
    const wide = instr.hw1 & ldst_wide.encodings.imm12 != 0;
    out.put("{s}{s}{s}{s}{s} ", .{
        if (f.load) "ldr" else "str",
        if (f.signed) "s" else "",
        switch (f.size) {
            1 => "b",
            2 => "h",
            else => "",
        },
        if (f.unprivileged) "t" else "",
        if (wide) ".w" else "",
    });
    out.reg(f.rt);
    out.put(", [", .{});
    out.reg(f.rn);
    if (wide or f.unprivileged) return dropZero(out, f.offset);
    if (!f.index) {
        out.put("], ", .{});
        if (f.add) return out.imm(f.offset);
        if (f.offset < text.decimal_below) return out.put("#-{d}", .{f.offset});
        return out.put("#-0x{x}", .{f.offset});
    }
    out.put(", ", .{});
    if (f.add) out.imm(f.offset) else out.put("#-0x{x}", .{f.offset});
    out.put("]{s}", .{if (f.writeback) "!" else ""});
}

/// `]` for a zero offset, `, #n]` otherwise.
fn dropZero(out: *text.Text, offset: u32) void {
    if (offset != 0) {
        out.put(", ", .{});
        out.imm(offset);
    }
    out.put("]", .{});
}
