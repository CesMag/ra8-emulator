//! Text for MVE interleaving loads/stores, per DDI0553 B5.
const Instr = @import("../../instr.zig").Instr;
const text = @import("../text.zig");

const sizes = [_][]const u8{ "8", "16", "32" };

pub fn print(instr: Instr, out: *text.Text) void {
    const count: u3 = if (instr.hw2 & 1 == 1) 4 else 2;
    const pattern = (instr.hw2 >> 5) & 3;
    const qd: u3 = @intCast(instr.hw2 >> 13);
    const load = instr.hw1 >> 4 & 1 == 1;
    const writeback = instr.hw1 >> 5 & 1 == 1;
    const rn = text.names[instr.hw1 & 15];
    const root = if (load) "vld" else "vst";
    out.put("{s}{d}{d}.{s} {{q{d}", .{ root, count, pattern, sizes[(instr.hw2 >> 7) & 3], qd });
    var i: u3 = 1;
    while (i < count) : (i += 1) out.put(", q{d}", .{qd + i});
    out.put("}}, [{s}]{s}", .{ rn, if (writeback) "!" else "" });
}
