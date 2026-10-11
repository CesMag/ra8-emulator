//! NVIC_ITNS, the Interrupt Target Non-secure registers.
//!
//! With the Security Extension, every external interrupt targets a security
//! state. ITNS holds one bit per line, thirty-two lines to a word: a one
//! sends the line to Non-secure state, a zero keeps it Secure, and reset
//! leaves every line Secure. Only Secure software can program it; from
//! Non-secure state the words read as zero and ignore writes.
//!
//!   NVIC_ITNS[0..15]  0xE000_E380 .. 0xE000_E3BC
//!   (Arm Armv8-M Exception Model User Guide, 107706, NVIC registers)
//!
//! This file answers which state a line targets, from the words as they
//! stand in the PPB. Taking an interrupt in that state (its vector table,
//! its banked stack and masks) and the Non-secure RAZ/WI view both need the
//! core's banked security state (RA8EMU-41).

const nvic = @import("nvic/nvic.zig");

pub const base: u32 = 0xE000_E380;
/// The last ITNS word the architecture defines.
pub const last: u32 = 0xE000_E3BC;

/// The words this part's lines reach.
pub const words: u32 = (nvic.irq_lines + 31) / 32;

pub const Target = enum { secure, non_secure };

pub const Error = error{NotAnIrq};

/// The ITNS word holding external interrupt `line`.
pub fn wordFor(line: u16) u32 {
    return base + 4 * (@as(u32, line) / 32);
}

/// The bit in that word for `line`.
pub fn bitFor(line: u16) u32 {
    return @as(u32, 1) << @as(u5, @intCast(line % 32));
}

/// The state external interrupt `line` targets.
pub fn target(core: anytype, line: u16) !Target {
    if (line >= nvic.irq_lines) return Error.NotAnIrq;
    const word = try core.readWord(wordFor(line));
    return if (word & bitFor(line) != 0) .non_secure else .secure;
}

/// The state exception `number` targets, for an external interrupt.
pub fn targetOf(core: anytype, number: u16) !Target {
    if (number < nvic.first_irq) return Error.NotAnIrq;
    return target(core, number - nvic.first_irq);
}
