//! What a report reads out of the GLCDC after a run (RA8EMU-631).
//!
//! A read through the bus counts a dark read when the graphics power domain
//! is off, and a report looking at a register afterwards must not: the
//! run's own count would change because somebody looked. Everything else a
//! GLCDC read does is already free of side effects, so a peek is the same
//! word cut to the same lanes. A dark block peeks zero, as it reads.
const glcdc = @import("glcdc.zig");
const lanes = @import("../lanes.zig");

/// The registry's peek for the GLCDC block.
pub fn thunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *glcdc.Glcdc = @ptrCast(@alignCast(context));
    if (!self.domain.powered()) return 0;
    const offset = address - glcdc.win_base;
    return lanes.part(self.readWord(lanes.word(offset)), lanes.lane(offset), width);
}
