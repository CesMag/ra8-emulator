//! Text for the branch_wide group: B<cond>.W (T3), B.W (T4) and BL, in
//! the spelling the parity digests pin, printed as the absolute target: `beq.w #0x2000104`,
//! `b.w #0x2000100`, `bl #0x2000104`.
const Instr = @import("../../instr.zig").Instr;
const text = @import("../text.zig");
const branch_wide = @import("../../ops/branch/wide.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    const e = branch_wide.encodings;
    switch (instr.hw2 & e.hw2_mask) {
        e.bl => {
            out.put("bl ", .{});
            out.target(instr.address, branch_wide.offset24(instr));
        },
        e.b => {
            out.put("b.w ", .{});
            out.target(instr.address, branch_wide.offset24(instr));
        },
        else => {
            out.put("b{s}.w ", .{text.conds[(instr.hw1 >> 6) & 0xF]});
            out.target(instr.address, branch_wide.offset20(instr));
        },
    }
}
