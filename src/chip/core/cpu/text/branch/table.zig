//! Text for the table_branch group: TBB and TBH, in the spelling the parity digests pin.
//! TBH names its scaling: `tbb [r1, r0]`, `tbh [pc, lr, lsl #1]`.
const Instr = @import("../../instr.zig").Instr;
const text = @import("../text.zig");
const table_branch = @import("../../ops/branch/table.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    const half = table_branch.isHalf(instr);
    out.put("{s} [", .{if (half) "tbh" else "tbb"});
    out.reg(@intCast(instr.hw1 & 0xF));
    out.put(", ", .{});
    out.reg(@intCast(instr.hw2 & 0xF));
    out.put("{s}]", .{if (half) ", lsl #1" else ""});
}
