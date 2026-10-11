//! Security attribution for one address: the SAU's answer combined with the
//! IDAU's, the way the Armv8-M SecurityCheck() pseudocode does it.
//!
//! This is the decision only. Enforcing it on fetches and data accesses, and
//! returning it from TT, needs the core to know which state it is in, and
//! that arrives with the banked state work (RA8EMU-41). Until then this is
//! what the enforcing hooks and the TT instructions will call.
//!
//! The rules, from SecurityCheck():
//!   * the debug and system ranges below are exempt and take the state of
//!     whatever is accessing them;
//!   * with SAU_CTRL.ENABLE clear, everything is Secure unless ALLNS is set;
//!   * with it set, an address in exactly one enabled region is Non-secure,
//!     or Non-secure callable when that region's NSC bit is set; an address
//!     in no region, or in more than one, is Secure;
//!   * the IDAU can only make an answer more secure, so the result is the
//!     more secure of the two.
//!
//! The RA8 IDAU map is not modelled here: its boundaries come from the
//! part's security attribution registers, and their addresses are not yet
//! verified against the manual. Callers pass the IDAU's answer in; with no
//! IDAU it is Non-secure, which leaves the SAU to decide.

const sau = @import("sau.zig");

/// Ordered so the more secure answer compares greater.
pub const State = enum(u2) {
    non_secure = 0,
    callable = 1,
    secure = 2,

    fn stricter(a: State, b: State) State {
        return if (@backingInt(a) >= @backingInt(b)) a else b;
    }
};

/// What the IDAU says about an address.
pub const Idau = struct {
    state: State = .non_secure,
    exempt: bool = false,
    region: ?u8 = null,
};

/// The attribution of one address.
pub const Attribution = struct {
    state: State,
    /// Exempt addresses take the accessing state; `state` is then
    /// meaningless and set to Secure so nothing reads it as permission.
    exempt: bool = false,
    /// The SAU region that decided it, when exactly one enabled region
    /// matched with the SAU on. TT reports this as SREGION with SRVALID.
    region: ?u8 = null,
    /// The IDAU region, for TT's IREGION and IRVALID.
    idau_region: ?u8 = null,
};

/// An inclusive span that SecurityCheck() exempts from attribution.
const Span = struct { first: u32, last: u32 };

/// ITM, DWT and FPB; the SCS; its Non-secure alias; TPIU and ETM; the ROM
/// table. Armv8-M ARM, SecurityCheck().
const exempt_spans = [_]Span{
    .{ .first = 0xE000_0000, .last = 0xE000_2FFF },
    .{ .first = 0xE000_E000, .last = 0xE000_EFFF },
    .{ .first = 0xE002_E000, .last = 0xE002_EFFF },
    .{ .first = 0xE004_0000, .last = 0xE004_1FFF },
    .{ .first = 0xE00F_F000, .last = 0xE00F_FFFF },
};

pub fn isExempt(address: u32) bool {
    for (exempt_spans) |span| {
        if (address >= span.first and address <= span.last) return true;
    }
    return false;
}

/// The SAU's answer alone.
pub fn fromSau(unit: *const sau.Sau, address: u32) Attribution {
    if (!unit.on()) {
        return .{ .state = if (unit.outsideIsNonSecure()) .non_secure else .secure };
    }
    var hit: ?u8 = null;
    for (unit.table, 0..) |region, index| {
        if (!region.covers(address)) continue;
        if (hit != null) return .{ .state = .secure };
        hit = @intCast(index);
    }
    const found = hit orelse return .{ .state = .secure };
    const callable = unit.table[found].callable;
    return .{ .state = if (callable) .callable else .non_secure, .region = found };
}

/// The full answer for `address`: exemption first, then the stricter of
/// the SAU's and the IDAU's.
pub fn attribute(unit: *const sau.Sau, idau: Idau, address: u32) Attribution {
    if (isExempt(address) or idau.exempt) {
        return .{ .state = .secure, .exempt = true, .idau_region = idau.region };
    }
    var answer = fromSau(unit, address);
    answer.state = State.stricter(answer.state, idau.state);
    answer.idau_region = idau.region;
    return answer;
}
