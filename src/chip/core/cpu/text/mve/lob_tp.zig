//! Text for the mve_lob_tp group (Armv8.1-M MVE), in Arm ARM syntax:
//! `dlstp.32 lr, rn`, `wlstp.8 lr, rn, #target`, `letp lr, #target` and
//! `lctp`. The size suffix is the element width; targets are absolute,
//! forward for WLSTP and backward for LETP, from the executor's own fields.
const Instr = @import("../../instr.zig").Instr;
const ops = @import("../../ops/mve/lob_tp.zig");
const text = @import("../text.zig");

const sizes = [4][]const u8{ "8", "16", "32", "64" };

pub fn print(instr: Instr, out: *text.Text) void {
    const f = ops.fields(instr) orelse return;
    const distance: i32 = @intCast(f.offset);
    switch (f.kind) {
        .dlstp => out.put("dlstp.{s} lr, {s}", .{ sizes[f.size], text.names[f.rn] }),
        .wlstp => {
            out.put("wlstp.{s} lr, {s}, ", .{ sizes[f.size], text.names[f.rn] });
            out.target(instr.address, distance);
        },
        .letp => {
            out.put("letp lr, ", .{});
            out.target(instr.address, -distance);
        },
        .lctp => out.put("lctp", .{}),
    }
}
