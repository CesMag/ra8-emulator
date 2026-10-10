//! Where the Non-secure MPU's registers live on the Zig core's bus
//! (RA8EMU-447).
//!
//! The MPU is banked between the Security states (DDI0553A.k B3.5): Secure
//! code on 0xE000_ED90.. programs the Secure MPU, Non-secure code on the
//! same addresses programs the Non-secure one, and Secure code reaches the
//! Non-secure MPU through the MPU_NS alias at 0xE002_ED90... Every MPU
//! register is banked whole, so the Non-secure copy is kept where wholly
//! banked SCS words keep theirs: the normal address + the alias offset.

const alias = @import("../scs_alias.zig");

/// MPU_TYPE through MPU_MAIR1, every byte.
pub const span = alias.Span{ .first = 0xE000_ED90, .last = 0xE000_EDC7 };

/// How far the Non-secure copy sits above the normal window.
pub const offset: u32 = alias.offset;

/// The Non-secure copy an access names, or null when it is not the
/// Non-secure view of an MPU register. `secure` is the accessing state.
pub fn copyOf(given: u32, secure: bool) ?u32 {
    const target = switch (alias.route(given, secure)) {
        .register => |t| t,
        .outside, .res0 => return null,
    };
    if (target.view != .non_secure or !span.covers(target.address)) return null;
    return target.address + offset;
}

/// The normal-window address of a Non-secure copy address, or null.
pub fn normalOf(address: u32) ?u32 {
    if (address < offset) return null;
    const normal = address - offset;
    return if (span.covers(normal)) normal else null;
}

/// Put the hardwired region count in the Non-secure MPU_TYPE too. TYPE is
/// banked like every MPU register, so without this Non-secure code reads a
/// zero DREGION through its own view and decides the MPU has no regions.
pub fn prime(core: anytype, type_value: u32) !void {
    try core.writeWord(span.first + offset, type_value);
}
