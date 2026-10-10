//! What each byte of the DTC window belongs to.
//!
//! The registers in this window are not one width. DTCCR is 8-bit at +0x00,
//! DTCVBR is 32-bit at +0x04, and DTCST (8-bit, +0x0C) and DTCSTS (16-bit,
//! +0x0E) SHARE THE WORD AT +0x0C. So an access here can name part of one
//! register (the high half of the vector base), or two whole registers at
//! once (the start bit and the status word in one word access), and the
//! answer has to be assembled a byte at a time.
//!
//! This file is only the map: which register owns a byte offset, which byte
//! of it that offset is, and whether the firmware may store there. The byte
//! arithmetic is `src/chip/periph/bytelanes.zig`, and what each register MEANS
//! stays in `src/chip/periph/dtc/dtc.zig`.

/// The registers the window answers for.
pub const Reg = enum { dtccr, dtcvbr, dtcst, dtcsts };

/// A byte offset resolved: the register it belongs to, and which byte of that
/// register it is. `index` is 0 for the low byte, so DTCSTS.ACT (bit 15) is
/// index 1.
pub const Place = struct {
    reg: Reg,
    index: u32,
};

/// Register offsets and widths inside the window, as ra8_dtc_regs.h has them.
pub const at = struct {
    pub const dtccr: u32 = 0x00;
    pub const dtcvbr: u32 = 0x04;
    pub const dtcst: u32 = 0x0C;
    pub const dtcsts: u32 = 0x0E;
};

const bytes = struct {
    const dtccr: u32 = 1;
    const dtcvbr: u32 = 4;
    const dtcst: u32 = 1;
    const dtcsts: u32 = 2;
};

/// Which register owns `offset` bytes into the window, or null when nothing
/// does: the reserved gaps at +0x01..0x03, +0x08..0x0B, +0x0D and everything
/// past DTCSTS read zero and hold nothing.
pub fn owner(offset: u32) ?Place {
    if (within(offset, at.dtccr, bytes.dtccr)) |index| return .{ .reg = .dtccr, .index = index };
    if (within(offset, at.dtcvbr, bytes.dtcvbr)) |index| return .{ .reg = .dtcvbr, .index = index };
    if (within(offset, at.dtcst, bytes.dtcst)) |index| return .{ .reg = .dtcst, .index = index };
    if (within(offset, at.dtcsts, bytes.dtcsts)) |index| return .{ .reg = .dtcsts, .index = index };
    return null;
}

/// Whether a store reaches the register at all. DTCSTS is written by the
/// controller, not by the firmware, so a store there is dropped rather than
/// shadowed: a driver that tries to clear ACT by hand does not get to.
pub fn writable(reg: Reg) bool {
    return reg != .dtcsts;
}

fn within(offset: u32, base: u32, width: u32) ?u32 {
    if (offset < base or offset >= base + width) return null;
    return offset - base;
}
