//! The MIPI DSI link status rule: what LINKSR, PLSR, VMSR and the two
//! sequence-channel status words say, given what the firmware has actually
//! programmed. Decode only, no window and no state; `dsi.zig` owns both.
//!
//! Bit positions are from ra8-firmware `libs/ra8_hal/inc/ra8_mipi_dsi_regs.h`
//! on `zig/dev`, which cites HUM Ch 65.2 page by page.

/// LINKSR (+0x010), read-only. The one the command path reads before every
/// send, so a wrong answer here refuses a perfectly good command.
pub const link = struct {
    pub const sq0run: u32 = 1 << 0;
    pub const sq1run: u32 = 1 << 4;
    pub const vrun: u32 = 1 << 8;
    pub const hsbusy: u32 = 1 << 12;
    pub const lpbusy: u32 = 1 << 13;
};

/// PLSR (+0x320), read-only. Level bits describe where the lanes are now;
/// the event bits latch until PLSCR clears them.
pub const phy = struct {
    pub const cluan: u32 = 1 << 0;
    pub const clstp: u32 = 1 << 1;
    pub const dl0uan: u32 = 1 << 4;
    pub const dl1uan: u32 = 1 << 5;
    pub const dl0stp: u32 = 1 << 8;
    pub const dl1stp: u32 = 1 << 9;
    pub const clulpent: u32 = 1 << 24;
    pub const clulpext: u32 = 1 << 25;
    pub const cllp2hs: u32 = 1 << 26;
    pub const clhs2lp: u32 = 1 << 27;
    pub const dlulpent: u32 = 1 << 28;
    pub const dlulpext: u32 = 1 << 29;
    /// k_ra8_mipi_dsi_plsr_clear_all, the events PLSCR can take down.
    pub const events: u32 = clulpent | clulpext | cllp2hs | clhs2lp | dlulpent | dlulpext;
};

/// VMSR (+0x410), read-only.
pub const video = struct {
    pub const running: u32 = 1 << 0;
    pub const virdy: u32 = 1 << 4;
    pub const stop: u32 = 1 << 8;
    pub const timerr: u32 = 1 << 20;
    pub const vbufudf: u32 = 1 << 22;
    pub const vbufovf: u32 = 1 << 23;
    pub const events: u32 = virdy | stop | timerr | vbufudf | vbufovf;
};

/// SQCHnSR (+0x5D0 / +0x610), read-only, and SQCHnSET0R's START bit.
pub const sequence = struct {
    pub const start: u32 = 1 << 0;
    pub const chsel: u32 = 1 << 23;
    pub const running: u32 = 1 << 2;
    pub const aactfin: u32 = 1 << 4;
    pub const adesfin: u32 = 1 << 8;
    pub const dabort: u32 = 1 << 16;
    pub const sizeerr: u32 = 1 << 19;
    /// What a transfer that completed with nothing on the far end reports.
    pub const finished: u32 = aactfin | adesfin;
};

/// RSTSR (+0x114), read-only.
pub const reset_status = struct {
    pub const rsths: u32 = 1 << 0;
    pub const rstlp: u32 = 1 << 1;
    pub const rstapb: u32 = 1 << 2;
    pub const rstaxi: u32 = 1 << 3;
    pub const rstv: u32 = 1 << 4;
    pub const dl0stp: u32 = 1 << 8;
    pub const dl1stp: u32 = 1 << 9;
    pub const all_reset: u32 = rsths | rstlp | rstapb | rstaxi | rstv;
};

/// HSCLKSETR (+0x104).
pub const hs_clock = struct {
    pub const start: u32 = 1 << 0;
    pub const continuous: u32 = 1 << 1;
};

/// RSTCR (+0x110).
pub const reset_control = struct {
    pub const swrst: u32 = 1 << 0;
    pub const ftxstp: u32 = 1 << 16;
};

/// VMSET0R (+0x400).
pub const video_control = struct {
    pub const vstart: u32 = 1 << 0;
    pub const vstop: u32 = 1 << 1;
};

/// ULPSCR (+0x10C), four pulses rather than a held state.
pub const ulps = struct {
    pub const clent: u32 = 1 << 24;
    pub const clexit: u32 = 1 << 25;
    pub const dlent: u32 = 1 << 28;
    pub const dlexit: u32 = 1 << 29;
};

/// Where the lanes are, which is what the PLSR level bits report.
pub const Lanes = struct {
    hs_clock: bool = false,
    clock_ulps: bool = false,
    data_ulps: bool = false,
};

/// LINKSR from the state the firmware put the block in. HSBUSY tracks the
/// HS clock because nothing else here holds the bus; LPBUSY is never set,
/// since a sequence completes inside the store that starts it.
pub fn linkWord(sq0: bool, sq1: bool, video_running: bool, lanes: Lanes) u32 {
    var word: u32 = 0;
    if (sq0) word |= link.sq0run;
    if (sq1) word |= link.sq1run;
    if (video_running) word |= link.vrun;
    if (lanes.hs_clock) word |= link.hsbusy;
    return word;
}

/// PLSR: the level bits for where the lanes are, plus whatever events are
/// still latched. A lane is "stopped" when it is not carrying HS traffic,
/// and UlpsActiveNot is the inverse of being parked in ULPS.
pub fn phyWord(lanes: Lanes, latched: u32) u32 {
    var word: u32 = latched & phy.events;
    if (!lanes.clock_ulps) word |= phy.cluan;
    if (!lanes.data_ulps) word |= phy.dl0uan | phy.dl1uan;
    if (!lanes.hs_clock) word |= phy.clstp;
    if (!lanes.hs_clock and !lanes.data_ulps) word |= phy.dl0stp | phy.dl1stp;
    return word;
}

/// VMSR: RUNNING is a level, the rest latch until VMSCR clears them.
pub fn videoWord(running: bool, latched: u32) u32 {
    const word: u32 = latched & video.events;
    return if (running) word | video.running else word;
}

/// RSTSR: everything held in reset while RSTCR.SWRST is asserted, and the
/// lane-stop bits once it is released and no HS clock is running.
pub fn resetWord(in_reset: bool, lanes: Lanes) u32 {
    if (in_reset) return reset_status.all_reset;
    if (lanes.hs_clock) return 0;
    return reset_status.dl0stp | reset_status.dl1stp;
}

pub fn startRequested(vmset0: u32) bool {
    return vmset0 & video_control.vstart != 0;
}

pub fn stopRequested(vmset0: u32) bool {
    return vmset0 & video_control.vstop != 0;
}

pub fn clockRunning(hsclksetr: u32) bool {
    return hsclksetr & hs_clock.start != 0;
}

pub fn continuousClock(hsclksetr: u32) bool {
    return hsclksetr & hs_clock.continuous != 0;
}

pub fn sequenceStarted(set0r: u32) bool {
    return set0r & sequence.start != 0;
}

pub fn inReset(rstcr: u32) bool {
    return rstcr & reset_control.swrst != 0;
}
