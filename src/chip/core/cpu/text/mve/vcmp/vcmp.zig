//! Text for integer VCMP and VPT, per DDI0553 B5.5.
const Instr = @import("../../../instr.zig").Instr;
const ops = @import("../../../ops/mve/vcmp/vcmp.zig");
const vpst = @import("../vpst.zig");
const text = @import("../../text.zig");
pub const fp = @import("fp.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    printPredicated(instr, out, "");
}

pub fn printPredicated(instr: Instr, out: *text.Text, suffix: []const u8) void {
    const f = ops.fields(instr) orelse return;
    const width = ([_][]const u8{ "8", "16", "32" })[@backingInt(f.size)];
    const signedness: []const u8 = switch (f.cond) {
        .cs, .hi => "u",
        .ge, .lt, .gt, .le => "s",
        .eq, .ne => "i",
    };
    const cond = @tagName(f.cond);
    if (f.mask != 0) {
        const pattern = vpst.pattern(instr);
        const extra = pattern.name[4..];
        out.put("vpt{s}.{s}{s} {s}, q{d}, ", .{ extra, signedness, width, cond, f.qn });
        if (f.scalar) out.put("{s}", .{text.names[f.rm]}) else out.put("q{d}", .{f.qm});
        return;
    }
    out.put("vcmp{s}.{s}{s} {s}, q{d}, ", .{ suffix, signedness, width, cond, f.qn });
    if (f.scalar) out.put("{s}", .{text.names[f.rm]}) else out.put("q{d}", .{f.qm});
}
