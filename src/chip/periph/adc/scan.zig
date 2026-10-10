//! What one A/D scan slot converts to: which group the slot belongs to, which
//! physical source it names, and the code that source reports.
//!
//! The register window next door in adc.zig owns the addresses and the scan
//! machine; this file owns the arithmetic, so neither has to carry the other.
//! Every function here is pure: give it a register word and it tells you what
//! the converter would answer.
//!
//! There is no analog core behind any of this. A mid-scale input is the only
//! honest thing to report for a pin nothing drives, and the self-diagnosis
//! codes are the IDEAL result for the armed mode, which is to say a healthy
//! SAR. A stuck converter cannot be injected here and stays a bench test.

/// ADCHCRn fields dev's own masks name.
pub const chcr = struct {
    /// SGSEL[4:0], the scan group the slot is enrolled in.
    pub const sgsel: u32 = 0x0000_001F;
    /// CNVCS[14:8], the physical source the slot samples.
    pub const cnvcs_mask: u32 = 0x0000_7F00;
    pub const cnvcs_shift: u5 = 8;
};

/// ADDOPCRCn.ADPRC[17:16], the slot's data format.
pub const opcrc = struct {
    pub const adprc_mask: u32 = 0x0003_0000;
    pub const adprc_shift: u5 = 16;
};

/// ADSGDCRn.DIAGVAL[2:0], the self-diagnosis mode armed for a group.
pub const sgdcr = struct {
    pub const diagval: u32 = 0x0000_0007;
};

/// ADDR / ADEXDR carry the code in DATA[15:0]; the bits above it are status.
pub const result = struct {
    pub const data: u32 = 0x0000_FFFF;
};

/// ADPRC[1:0] data formats (HUM Ch 53.2.3.4 p 3339) and the half-full-scale
/// code each one reports for a mid-scale input.
pub const Format = enum(u2) {
    bits16 = 0,
    bits14 = 1,
    bits12 = 2,
    bits10 = 3,

    pub fn midscale(self: Format) u16 {
        return switch (self) {
            .bits16 => 0x8000,
            .bits14 => 0x2000,
            .bits12 => 0x0800,
            .bits10 => 0x0200,
        };
    }
};

/// The internal sources. A CNVCS at or above `base` samples no pin: it routes
/// an on-chip source and reports through ADEXDR[CNVCS - base] rather than the
/// ordinary ADDR slot (HUM Ch 53.2.13.2 p 3391).
pub const ext = struct {
    pub const base: u32 = 0x60;
    pub const selfdiag: u32 = 0x60;
    pub const temperature: u32 = 0x64;
    pub const int_vref: u32 = 0x65;
};

/// The self-diagnosis modes and their ideal results (HUM Table 53.19 p 3412).
pub const diag = struct {
    pub const mode1: u32 = 0x4;
    pub const mode2: u32 = 0x5;
    pub const mode3: u32 = 0x6;

    pub const zero: u16 = 0x0000;
    pub const negative_full_scale: u16 = 0x8000;
    pub const positive_full_scale: u16 = 0x7FFF;
};

/// The die-temperature code. Paired with the factory calibration board
/// attach seeds at 0x02C1EDA0 (tsn_cal.zig), the two-point conversion
/// in the firmware's TSN driver maps this to 26 degrees, a plausible
/// deterministic die.
pub const temperature_code: u16 = 1800;

/// What any other internal source reports: a 12-bit half-scale sample.
pub const sample_code: u16 = 2048;

/// One configured slot, as ADCHCRn describes it.
pub const Slot = struct {
    group: u32,
    source: u32,

    pub fn decode(word: u32) Slot {
        return .{
            .group = word & chcr.sgsel,
            .source = (word & chcr.cnvcs_mask) >> chcr.cnvcs_shift,
        };
    }

    /// True when the source is an on-chip one, which reports through ADEXDR.
    pub fn internal(self: Slot) bool {
        return self.source >= ext.base;
    }

    /// The ADEXDR index this source answers on. Only meaningful for an
    /// internal source, so the caller asks `internal` first.
    pub fn extIndex(self: Slot) u32 {
        return self.source - ext.base;
    }
};

/// The data format a slot's ADDOPCRCn word selects.
pub fn format(opcrc_word: u32) Format {
    const code: u2 = @truncate((opcrc_word & opcrc.adprc_mask) >> opcrc.adprc_shift);
    return @fromBackingInt(@intCast(code));
}

/// The ideal result for an armed self-diagnosis mode. Anything that is not
/// mode 2 or mode 3, including the mode-off encoding, drives zero.
pub fn selfDiagnosis(diagval: u32) u16 {
    return switch (diagval & sgdcr.diagval) {
        diag.mode2 => diag.negative_full_scale,
        diag.mode3 => diag.positive_full_scale,
        else => diag.zero,
    };
}

/// What an internal source reports, given the group's self-diagnosis mode.
pub fn internalValue(source: u32, diagval: u32) u16 {
    return switch (source) {
        ext.selfdiag => selfDiagnosis(diagval),
        ext.temperature => temperature_code,
        else => sample_code,
    };
}
