//! Text for the ldr.literal group: LDR Rt, [pc, #imm], 16-bit. We keep
//! the `#0` here even though it drops it for other zero offsets.
const Instr = @import("../../../instr.zig").Instr;
const text = @import("../../text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    out.put("ldr {s}, [pc, ", .{text.names[text.low(instr.hw1, 8)]});
    out.imm((instr.hw1 & 0xFF) << 2);
    out.put("]", .{});
}
