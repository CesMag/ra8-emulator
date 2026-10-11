//! Where the Zig core asks which security state an address belongs to
//! (RA8EMU-357).
//!
//! The board builds one from src/chip/periph/sau/attribution.zig, which combines the SAU
//! with the IDAU. A core with no source treats every address as Secure, the
//! way it behaved before this seam existed, so nothing changes for a board
//! that does not set one.
//!
//! The source answers for a Non-secure fetch: an exempt address takes the
//! accessing state, so it should answer non_secure.
const sau_attr = @import("../../periph/sau/attribution.zig");
const tt = @import("../tt.zig");
const Instr = @import("instr.zig").Instr;
const sg = @import("ops/sg.zig");

pub const State = sau_attr.State;

pub const Attribution = struct {
    context: *anyopaque,
    stateFn: *const fn (context: *anyopaque, address: u32) State,
    /// The TT_RESP word for `target` (RA8EMU-352). A source without one
    /// answers every address as Secure, the way the core did before.
    respondFn: ?*const fn (context: *anyopaque, target: u32, secure: bool) u32 = null,

    pub fn of(self: Attribution, address: u32) State {
        return self.stateFn(self.context, address);
    }
};

/// The state `address` belongs to, or Secure when there is no source.
pub fn state(source: ?Attribution, address: u32) State {
    return if (source) |s| s.of(address) else .secure;
}

/// What TT answers for `target`. With no source every address is Secure;
/// the MPU half is the disabled-MPU answer, R and RW set, as in src/chip/core/tt.zig.
pub fn respond(source: ?Attribution, target: u32, secure: bool) u32 {
    if (source) |s| if (s.respondFn) |answer| return answer(s.context, target, secure);
    const word = tt.field.r | tt.field.rw;
    return if (secure) word | tt.field.s else word;
}

/// Whether Non-secure code may not run what it fetched (RA8EMU-359): Secure
/// memory refuses every instruction, Non-secure callable memory everything
/// but SG. The core takes SecureFault INVEP instead of running it.
pub fn refusesEntry(source: ?Attribution, instr: Instr) bool {
    const s = source orelse return false;
    return switch (s.of(instr.address)) {
        .non_secure => false,
        .secure => true,
        .callable => !isSg(instr),
    };
}

/// Whether Secure code may not run what it fetched (RA8EMU-473): a fetch
/// from Non-secure memory while the core is still Secure means a branch
/// reached it without BXNS, BLXNS or an exception return switching state,
/// so the core takes SecureFault INVTRAN instead (DDI0553A.k, SFSR.INVTRAN).
/// Exempt ranges take the accessing state, so they never count.
pub fn refusesTransition(source: ?Attribution, address: u32) bool {
    const s = source orelse return false;
    if (sau_attr.isExempt(address)) return false;
    return s.of(address) == .non_secure;
}

fn isSg(instr: Instr) bool {
    return instr.size == 4 and instr.hw1 == sg.encoding and instr.hw2 == sg.encoding;
}
