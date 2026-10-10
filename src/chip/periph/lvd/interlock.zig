//! The two prohibited RHSEL/RI/RN combinations on a PVDm channel.
//!
//! Its own file rather than a prong inside lvd.zig, the way
//! field_lock.zig sits beside it for the FSAMP rule.
//!
//! BOTH RULES ARE ONE INTERLOCK SEEN FROM ITS TWO SIDES. RHSEL picks which
//! way the comparator drives the reset path: 0 is the LVD band, a fall
//! below Vdet, and 1 is the HVD band, a rise above it. RI arms that reset
//! path and RN says when it negates. The part refuses the two combinations
//! that would leave a band selected with no coherent reset behind it.
//!
//! RHSEL = 1 NEEDS RI ALREADY SET. HUM Ch 8.2.8 "PVDmFCR" p 308 last
//! bullet, restated at Ch 12.2.8 p 600 and quoted in ra8_lvd_runtime.c at
//! ra8_lvd_set_hysteresis_mode: "RHSEL must not be set to 1 when
//! PVDmCR0.RI = 0." The driver checks it and answers
//! k_ra8_err_invalid_state rather than making the store, so the ordering
//! that does work is RI first and the band second. That is exactly what
//! the reset_on_rise response does (m: RI = 1 and RIE = 1, then RHSEL = 1).
//!
//! RN = 1 IS PROHIBITED WHILE RHSEL = 1. HUM Ch 8.2.4 "RN bit" p 305,
//! restated at Ch 12.2.4 p 597 and quoted in ra8_lvd_types.h: with the
//! rise-detect band selected there is no "after VCC clears Vdet" moment
//! for the negation to hang off, so only RN = 0 is defined.
//!
//! M CHANNELS ONLY. PVD4 and PVD5 are reset-only and have neither RI nor
//! RN (Ch 8.2.5 p 306 gives PVDnCR0 an RE bit instead), so their RHSEL is
//! always legal and nothing here gates them.
//!
//! ONLY THE STORE IS GATED, AND THAT IS NOT A SHORTCUT. Both pages forbid
//! REACHING the combination, and neither says what the part does if RI is
//! cleared later while RHSEL already stands, or if RHSEL is raised while
//! RN already stands. Guessing an unwind would invent behaviour, so a
//! standing bit is left exactly as the firmware left it and only the write
//! that would have created the combination is refused.
//!
//! THE THIRD RULE ON PVDmFCR IS NOT HERE. RHSEL can also only be modified
//! while every PVDmCMPCR.PVDE and PVDnCMPCR.PVDE bit is 0 (Ch 8.2.8 p 308,
//! quoted in ra8_lvd_api.h:322). That is the same gate the deferred PVDLVL
//! rule needs, it carries the same open question, and the driver itself
//! only clears its OWN channel's PVDE around the write and tells the
//! caller to serialise the rest. It belongs with that slice, not this one.
const regs = @import("regs.zig");

/// The refusals, counted per block: which channel reached for a prohibited
/// combination is not something a reader would act on differently.
pub const Locked = struct {
    /// RHSEL = 1 stores dropped because the reset path was not armed.
    bands: u32 = 0,
    /// RN = 1 stores dropped because the rise-detect band was selected.
    negations: u32 = 0,

    pub fn quiet(self: *const Locked) bool {
        return self.bands == 0 and self.negations == 0;
    }

    /// What a store to PVDmFCR actually lands.
    pub fn band(self: *Locked, series: regs.Series, cr0: u8, value: u8) u8 {
        const wanted = value & regs.hysteresis.rhsel;
        if (series != .monitor or wanted == 0) return wanted;
        if (cr0 & regs.control.ri != 0) return wanted;
        self.bands +%= 1;
        return 0;
    }

    /// What the RN bit of a store to PVDmCR0 actually lands.
    pub fn negate(self: *Locked, series: regs.Series, fcr: u8, current: u8, value: u8) u8 {
        if (series != .monitor) return value;
        if (value & regs.control.rn == 0) return value;
        if (fcr & regs.hysteresis.rhsel == 0) return value;
        if (current & regs.control.rn != 0) return value;
        self.negations +%= 1;
        return value & ~regs.control.rn;
    }
};
