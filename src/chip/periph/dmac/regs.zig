//! The DMAC channel register window, and what an access of each width names
//! inside it.
//!
//! Split out of `src/chip/periph/dmac/dmac.zig`, which owns the transfers, the module
//! gate and the counters. This file owns the map alone: which registers a word
//! holds, which lanes of that word each one occupies, and which lanes are
//! reserved.
//!
//! THE REGISTERS ARE NOT ALL WORDS, AND THREE OF THEM SHARE ONE (HUM Ch 16,
//! ra8_dmac_regs.h):
//!
//!   0x00  DMSAR  32b            source address
//!   0x04  DMDAR  32b            destination address
//!   0x08  DMCRA  32b            the count, reloaded and running
//!   0x0C  DMCRB  16b in byte 0  blocks left
//!   0x10  DMTMD  16b in the low half, DMINT 8b in byte 3
//!   0x14  DMAMD  16b in the low half
//!   0x18  DMOFR  32b            the offset an offset-mode transfer adds
//!   0x1C  DMCNT  8b in byte 0, DMREQ 8b in byte 1, DMSTS 8b in byte 2
//!
//! `dmac.zig` used to switch on the exact byte offset of an access and ignore
//! its width, so only an access that started precisely on a register reached
//! it. Two things followed, both of them wrong on silicon.
//!
//! A NARROW READ ANYWHERE ELSE IN A WORD ANSWERED ZERO. A driver dumping the
//! programmed source address a halfword at a time read DMSAR's top half at
//! +0x02 and got nothing, so its own read-back check failed against registers
//! it had just written correctly.
//!
//! A STORE THAT SPANNED MORE THAN ONE REGISTER REACHED ONLY THE FIRST. The
//! word at +0x1C is the one that matters: a halfword store there carries
//! DMCNT.DTE in the byte it starts at and DMREQ.SWREQ in the byte above, which
//! is how a driver arms a channel and asks for the transfer in one store. The
//! arm landed, the request was dropped on the floor, and the firmware waited
//! on a transfer-end flag for a transfer nobody had asked for.
//!
//! The rule now is the bus's, the same one `src/chip/periph/lanes.zig` already
//! serves the PORT, SCI, ELC and ICU windows: a read is served from the word
//! the access lands in and cut to the lanes it names, a narrow store is merged
//! into that word so the lanes it does not name keep what they had, and a lane
//! no register occupies reads zero and holds nothing.

/// Per-channel register offsets (the subset a driver touches).
pub const off = struct {
    pub const dmsar: u32 = 0x00;
    pub const dmdar: u32 = 0x04;
    pub const dmcra: u32 = 0x08;
    pub const dmcrb: u32 = 0x0C;
    pub const dmtmd: u32 = 0x10;
    pub const dmint: u32 = 0x13;
    pub const dmamd: u32 = 0x14;
    pub const dmofr: u32 = 0x18;
    pub const dmcnt: u32 = 0x1C;
    pub const dmreq: u32 = 0x1D;
    pub const dmsts: u32 = 0x1E;
};

pub const field = struct {
    /// DMCNT.DTE b0: this channel is armed.
    pub const dte: u8 = 0x01;
    /// DMREQ.SWREQ b0: the software transfer request.
    pub const swreq: u8 = 0x01;
    /// DMREQ.CLRS b4: keep the request set, so one store drains the count.
    pub const clrs: u8 = 0x10;
    /// DMINT.DTIE b4: interrupt the CPU when the count is spent.
    pub const dtie: u8 = 0x10;
    /// DMSTS.DTIF b4: transfer-end status, write 0 to clear.
    pub const dtif: u8 = 0x10;
    /// DMSTS.ACT b7: a transfer is in progress.
    pub const act: u8 = 0x80;
};

/// The lanes of a word a register occupies.
pub const lane = struct {
    pub const half: u32 = 0x0000_FFFF;
    pub const byte0: u32 = 0x0000_00FF;
    pub const byte1: u32 = 0x0000_FF00;
    pub const byte2: u32 = 0x00FF_0000;
    pub const byte3: u32 = 0xFF00_0000;
};

/// What a store asked the controller for beyond the registers it wrote.
pub const Request = struct {
    /// DMREQ.CLRS was set with it, so the request stays asserted and one
    /// store drains the whole count.
    continuous: bool,
};

/// The word at `base` as the bus sees it, with the registers sharing it packed
/// into their lanes. DMREQ has no lane here: the request is spent inside the
/// store that makes it, so nothing holds a value to read back.
pub fn wordValue(channel: anytype, base: u32) u32 {
    return switch (base) {
        off.dmsar => channel.dmsar,
        off.dmdar => channel.dmdar,
        off.dmcra => channel.dmcra,
        off.dmcrb => channel.dmcrb,
        off.dmtmd => @as(u32, channel.dmtmd) | (@as(u32, channel.dmint) << 24),
        off.dmamd => channel.dmamd,
        off.dmofr => channel.dmofr,
        off.dmcnt => @as(u32, channel.dmcnt) | (@as(u32, channel.dmsts) << 16),
        else => 0,
    };
}

/// Fold a store into the registers the access named. `merged` is the whole
/// word after the merge and `named` the lanes the access actually names, so a
/// register the access did not reach is not written back over itself.
///
/// The one ordering that matters is inside the word at +0x1C: DMCNT is applied
/// first, so a store that arms and requests at once is armed by the time the
/// request is answered, and DMSTS is cleared before the request runs so the
/// flag this transfer raises is not cleared by the same store that asked for
/// it. The request itself is the caller's to run, because it moves memory.
pub fn apply(channel: anytype, base: u32, merged: u32, named: u32) ?Request {
    if (named == 0) return null;
    switch (base) {
        off.dmsar => channel.dmsar = merged,
        off.dmdar => channel.dmdar = merged,
        off.dmcra => channel.dmcra = merged,
        off.dmcrb => channel.dmcrb = merged,
        off.dmofr => channel.dmofr = merged,
        off.dmtmd => {
            if (named & lane.half != 0) channel.dmtmd = @truncate(merged);
            if (named & lane.byte3 != 0) channel.dmint = @truncate(merged >> 24);
        },
        off.dmamd => {
            if (named & lane.half != 0) channel.dmamd = @truncate(merged);
        },
        off.dmcnt => return control(channel, merged, named),
        else => {},
    }
    return null;
}

/// The word DMCNT, DMREQ and DMSTS share.
fn control(channel: anytype, merged: u32, named: u32) ?Request {
    if (named & lane.byte0 != 0) count(channel, @truncate(merged));
    if (named & lane.byte2 != 0) channel.dmsts &= @truncate(merged >> 16);
    if (named & lane.byte1 == 0) return null;
    const asked: u8 = @truncate(merged >> 8);
    if (asked & field.swreq == 0) return null;
    return .{ .continuous = asked & field.clrs != 0 };
}

/// DMCNT.DTE going up latches the counts, the way silicon does: a channel
/// whose count is spent has to be re-armed before it moves again.
fn count(channel: anytype, value: u8) void {
    const raising = value & field.dte != 0 and !channel.armed();
    channel.dmcnt = value;
    if (raising) channel.arm();
}
