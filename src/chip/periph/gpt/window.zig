//! Where a GPT channel's registers sit, and how a narrow store finds one.
//!
//! A channel window is 0x100 wide (ra8_gpt_regs.h `r_gpt_channel_regs_t`,
//! HUM Ch 22 register map p 879) and this model interprets eight of its
//! words; the rest it shadows. Two questions come up on every access and
//! neither belongs to the counting: which word a byte offset lands in, so a
//! byte or half-word store reaches the right register instead of falling
//! through to the shadow, and whether GTWP's protection covers that word.
//!
//! THOSE TWO QUESTIONS USED TO HAVE ONE ANSWER. `interpreted` served as the
//! protected set as well, on the reasoning that the registers this model
//! reads are the ones the HAL brackets between the GTWP keys. That is true
//! of every register but one, and the exception is the one a polling driver
//! leans on hardest: GTST.
//!
//! GTST IS NOT PROTECTED. Neither tree carries HUM's table of protected
//! registers, so the HAL's own bracketing is the evidence available, and it
//! is unambiguous. Across ra8_gpt.c's twenty-two bracketed windows, fifteen
//! registers are only ever written between `k_ra8_gtwp_key_unlock` and
//! `k_ra8_gtwp_key_lock`: GTCCR, GTCNT, GTCR, GTDNSR, GTDTCR, GTDVD, GTDVU,
//! GTICASR, GTICBSR, GTIOR, GTPBR, GTPR, GTSTP, GTSTR and GTUPSR. Exactly
//! one register is written with no bracket anywhere in the file, at both of
//! its two sites: GTST, in `ra8_gpt_clear_status` (line 425) and in
//! `internal_dispatch` (line 891), the ISR path that acknowledges the flag
//! it was entered for. A driver that has to unlock before acknowledging an
//! interrupt would be a strange thing to ship, and this one does not.
//!
//! The confirmation is that the firmware runs. gpt_one_shot_demo sits in
//! examples/ek_ra8d2/hw_validated/hil/, the tree's hardware-validated set,
//! and its inner loop is `ra8_gpt_get_status` until GTST.TCFPO shows, then
//! `ra8_gpt_clear_status` to drop it, with its hil.conf asserting the
//! counter advances at least ten times and the mismatch counter stays at
//! zero. `ra8_gpt_start_free_run` locks the channel on its way out, so every
//! one of those clears arrives with GTWP shut. If the part refused them the
//! flag would stand, and the app passed on the bench.
const std = @import("std");

const buf = @import("buffer.zig");
const compare = @import("compare.zig");

/// Channel-local offsets of the registers this model interprets
/// (ra8_gpt_regs.h lines 55..80).
pub const off = struct {
    pub const gtstr: u32 = 0x04;
    pub const gtstp: u32 = 0x08;
    pub const gtclr: u32 = 0x0C;
    pub const gtcr: u32 = 0x2C;
    pub const gtst: u32 = 0x3C;
    pub const gtcnt: u32 = 0x48;
    pub const gtpr: u32 = 0x64;
    pub const gtpbr: u32 = 0x68;
};

/// The words this model interprets, as opposed to the rest of the window it
/// only shadows.
const cells = [_]u32{
    off.gtstr,     off.gtstp, off.gtclr, off.gtcr,
    off.gtst,      off.gtcnt, off.gtpr,  off.gtpbr,
    buf.off.gtber,
};

/// The register a byte offset belongs to, so a narrow store lands on the
/// right word instead of falling through to the shadow.
pub fn cellOf(local: u32) u32 {
    for (cells) |cell| {
        if (local >= cell and local < cell + 4) return cell;
    }
    return local;
}

/// Does this model interpret the register at this offset, as opposed to
/// only shadowing it?
pub fn interpreted(local: u32) bool {
    if (compare.which(local) != null or buf.which(local) != null) return true;
    for (cells) |cell| {
        if (local >= cell and local < cell + 4) return true;
    }
    return false;
}

/// Does GTWP's protection cover the register at this offset? The set the
/// HAL brackets between its keys, which is everything this model interprets
/// except GTST, and GTWP itself is outside it either way.
pub fn protected(local: u32) bool {
    if (local >= off.gtst and local < off.gtst + 4) return false;
    return interpreted(local);
}

/// One byte lane out of a word.
pub fn lane(value: u32, index: u32) u8 {
    return @truncate(value >> @intCast(index * 8));
}

/// A word with one byte lane replaced.
pub fn merge(value: u32, index: u32, byte: u8) u32 {
    const shift: u5 = @intCast(index * 8);
    const mask = ~(@as(u32, 0xFF) << shift);
    return (value & mask) | (@as(u32, byte) << shift);
}
