//! The generic short-packet FIFO rule for MIPI CSI-2: what GSCT asks for,
//! what GSST answers, and what GSIU does to it.
//!
//! This is decode only. The block in csi.zig owns the FIFO itself and
//! the counters; everything here is a pure function of the words, so the
//! clear handshake can be stated once and tested on its own.
//!
//! Field positions are from ra8-firmware libs/ra8_hal/inc/ra8_mipi_csi_regs.h
//! on zig/dev, which cites HUM Ch 66.3.24-66.3.29 pp 3956-3960.

/// GSCT: what the firmware asks the FIFO to do.
pub const control = struct {
    /// SHTH[6:0], the queue depth at which GTH is raised.
    pub const threshold: u32 = 0x0000_007F;
    /// GFIF[16], storing received short packets at all.
    pub const store: u32 = 0x0001_0000;
};

/// GSST: what the FIFO answers. GNE, GTH, GOV and PNUM are the queue;
/// GCD is the clear handshake; STRDS says storing is off.
pub const status = struct {
    pub const not_empty: u32 = 0x0000_0001;
    pub const threshold_met: u32 = 0x0000_0002;
    pub const overflow: u32 = 0x0000_0010;
    pub const count: u32 = 0x0000_FF00;
    pub const count_shift: u5 = 8;
    pub const cleared: u32 = 0x0001_0000;
    pub const store_disabled: u32 = 0x0002_0000;
};

/// GSIU: the three things the firmware can drive at the FIFO.
pub const update = struct {
    /// FINC[0], advance the read pointer by one packet.
    pub const advance: u32 = 0x0000_0001;
    /// GFCLR[8], hold the clear request until GCD comes back.
    pub const clear: u32 = 0x0000_0100;
    /// GFEN[16], re-enable storing after an overflow.
    pub const reenable: u32 = 0x0001_0000;
};

/// GSHT: the header word a queued packet is read out as.
pub const header = struct {
    pub const payload: u32 = 0x0000_FFFF;
    pub const payload_shift: u5 = 0;
    pub const data_type: u32 = 0x003F_0000;
    pub const data_type_shift: u5 = 16;
    pub const channel: u32 = 0x0F00_0000;
    pub const channel_shift: u5 = 24;
};

/// FIFO depth, MCG.GSNM on this part.
pub const depth: u32 = 16;

pub fn storing(gsct: u32) bool {
    return gsct & control.store != 0;
}

pub fn thresholdOf(gsct: u32) u32 {
    return gsct & control.threshold;
}

pub fn clearRequested(gsiu: u32) bool {
    return gsiu & update.clear != 0;
}

pub fn advanceRequested(gsiu: u32) bool {
    return gsiu & update.advance != 0;
}

pub fn reenableRequested(gsiu: u32) bool {
    return gsiu & update.reenable != 0;
}

/// GSST built from the queue state. `queued` is the packet count, `cleared`
/// is whether a clear has completed and not yet been released, `storing` is
/// GSCT.GFIF.
pub fn value(queued: u32, limit: u32, cleared_now: bool, storing_now: bool) u32 {
    var word: u32 = (queued << status.count_shift) & status.count;
    if (queued != 0) word |= status.not_empty;
    if (limit != 0 and queued >= limit) word |= status.threshold_met;
    if (cleared_now) word |= status.cleared;
    if (!storing_now) word |= status.store_disabled;
    return word;
}

pub fn queuedIn(gsst: u32) u32 {
    return (gsst & status.count) >> status.count_shift;
}

/// The header word for a packet, as GSHT reads it back.
pub fn headerWord(data_type: u32, channel: u32, payload: u32) u32 {
    return ((payload << header.payload_shift) & header.payload) |
        ((data_type << header.data_type_shift) & header.data_type) |
        ((channel << header.channel_shift) & header.channel);
}
