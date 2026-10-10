//! Option-setting memory, read once the image is in place.
//!
//! The boot ROM reads OFS0 before the first instruction runs, so whoever
//! builds the chip reads it at the same point: after the image is loaded,
//! before the core starts. An address the image left unwritten reads as an
//! erased part. This is MCU flash behaviour, the same on any board.
const iwdt = @import("iwdt.zig");

/// Hand the image's OFS0 word to the blocks it configures at reset.
pub fn apply(watchdog: *iwdt.Iwdt, core: anytype) void {
    const word = core.readWord(iwdt.ofs0.address) catch iwdt.ofs0.erased;
    watchdog.applyOptionWord(word);
}
