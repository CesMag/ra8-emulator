//! Text for VPNOT and VPSEL, per DDI0553 B5.5 and C2.4.426-428.
const Instr = @import("../../instr.zig").Instr;
const text = @import("../text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    printPredicated(instr, out, "");
}

pub fn printPredicated(instr: Instr, out: *text.Text, suffix: []const u8) void {
    if (instr.hw1 == 0xFE31 and instr.hw2 == 0x0F4D) return out.put("vpnot", .{});
    const qd: u3 = @intCast(instr.hw2 >> 13);
    const qn: u3 = @intCast(instr.hw1 >> 1 & 7);
    const qm: u3 = @intCast(instr.hw2 >> 1 & 7);
    out.put("vpsel{s} q{d}, q{d}, q{d}", .{ suffix, qd, qn, qm });
}
