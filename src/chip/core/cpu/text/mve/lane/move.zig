//! Text for scalar/vector single-lane VMOV, per DDI0553 B5.4 and C2.4.528.
const Instr = @import("../../../instr.zig").Instr;
const ops = @import("../../../ops/mve/lane/move.zig");
const text = @import("../../text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    const lane = ops.laneOf(instr) orelse return;
    const rt: u4 = @intCast(instr.hw2 >> 12);
    const to_lane = instr.hw1 & ops.encodings.to_lane_hw1_mask == ops.encodings.to_lane_hw1;
    if (to_lane) {
        const width = switch (lane.size) {
            .byte => "8",
            .half => "16",
            .word => "32",
        };
        return out.put("vmov.{s} q{d}[{d}], {s}", .{ width, lane.q, lane.elem, text.names[rt] });
    }
    const data_type = switch (lane.size) {
        .byte => if (instr.hw1 >> 7 & 1 == 1) "u8" else "s8",
        .half => if (instr.hw1 >> 7 & 1 == 1) "u16" else "s16",
        .word => "32",
    };
    out.put("vmov.{s} {s}, q{d}[{d}]", .{ data_type, text.names[rt], lane.q, lane.elem });
}
