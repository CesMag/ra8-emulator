//! The board's SAU as the Zig core's attribution source (RA8EMU-352).
//!
//! The firmware programs the SAU the board keeps (src/chip/periph/sau/sau.zig); this
//! answers the core's two questions from it: which state a fetched address
//! belongs to (SG, the INVEP check) and what TT reports for a target.
//! The IDAU is the board's RA8 map when it gives one (RA8EMU-277, address
//! bit 28 and SRAMSABARn); with none it is the empty IDAU, which leaves the
//! SAU to decide, as it did before.
const sau = @import("../../periph/sau/sau.zig");
const sau_attr = @import("../../periph/sau/attribution.zig");
const tt = @import("../tt.zig");
const attribution = @import("attribution.zig");

pub const SauSource = struct {
    unit: *const sau.Sau,
    idau: ?*const sau.idau.Map = null,

    pub fn source(self: *SauSource) attribution.Attribution {
        return .{ .context = self, .stateFn = state, .respondFn = respond };
    }

    /// An exempt address takes the accessing state. The core asks this
    /// only for a Non-secure fetch, so exempt answers Non-secure.
    fn state(context: *anyopaque, address: u32) attribution.State {
        const self: *SauSource = @ptrCast(@alignCast(context));
        const answer = sau_attr.attribute(self.unit, self.idauAt(address), address);
        return if (answer.exempt) .non_secure else answer.state;
    }

    fn respond(context: *anyopaque, target: u32, secure: bool) u32 {
        const self: *SauSource = @ptrCast(@alignCast(context));
        return tt.respondWith(self.unit, self.idauAt(target), target, secure);
    }

    fn idauAt(self: *const SauSource, address: u32) sau_attr.Idau {
        const map = self.idau orelse return .{};
        return map.answer(address);
    }
};
