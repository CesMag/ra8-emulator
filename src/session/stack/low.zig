//! How deep a core's main stack went (RA8EMU-816): the lowest MSP since
//! reset against the reservation the image's linker symbols name. A low
//! mark under the reservation's base overflowed it by the difference.
const zig_core = @import("../zig/core.zig");
const region_map = @import("../region/map/map.zig");
const never_low = @import("ra8_chip").core.cpu.regs.never_low;

pub const Report = struct {
    marks: zig_core.StackMarks,
    /// The reservation, when the image names one.
    stack: ?region_map.Stack,

    /// Whether anything has set the MSP since reset.
    pub fn touched(self: Report) bool {
        return self.marks.low_msp != never_low;
    }

    /// Bytes the lowest MSP sat under the reservation's base: zero when it
    /// stayed inside, was never set, or the image names no reservation.
    pub fn overflowBytes(self: Report) u32 {
        const stack = self.stack orelse return 0;
        if (!self.touched()) return 0;
        return stack.base -| self.marks.low_msp;
    }
};
