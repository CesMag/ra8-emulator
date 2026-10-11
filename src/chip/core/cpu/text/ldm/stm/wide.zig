//! Text for the ldm_stm_wide group: the 32-bit load and store multiple, in
//! the spelling the parity digests pin. The increment-after forms carry `.w` (`stm.w`,
//! `ldm.w`); the decrement-before forms do not (`stmdb`, `ldmdb`).
//! STMDB SP! and LDM SP! with two or more registers print as `push.w` and
//! `pop.w`; with one register they keep the plain spelling.
const Instr = @import("../../../instr.zig").Instr;
const text = @import("../../text.zig");
const Form = @import("../../../ops/ldm/stm/wide.zig").Form;

const sp: u4 = 13;

pub fn print(instr: Instr, out: *text.Text) void {
    const f = Form.of(instr) orelse return;
    const stack = f.rn == sp and f.wback and f.load != f.before and @popCount(f.list) >= 2;
    if (stack) {
        out.put("{s} ", .{if (f.load) "pop.w" else "push.w"});
    } else {
        out.put("{s}{s} ", .{
            if (f.load) "ldm" else "stm",
            if (f.before) "db" else ".w",
        });
        out.reg(f.rn);
        out.put("{s}, ", .{if (f.wback) "!" else ""});
    }
    out.list(f.list);
}
