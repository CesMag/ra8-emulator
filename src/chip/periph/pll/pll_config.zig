//! One PLL's configuration pair, PLLmCCR and PLLmCCR2, and what a store does
//! to them once the bus has decided the access is allowed.
//!
//! Split out of src/chip/periph/pll/pll.zig when PLL2 arrived. That file owns the bus
//! side, the PRCR gate and MOSCWTCR; this one owns a single PLL's two words,
//! the counters for stores that went nowhere, and the two rules that decide
//! between them. Both PLLs get one of these, so the rules are written once.
//!
//! THE FIELD LAYOUT IS THE SAME FOR BOTH, which is the whole reason this file
//! is shared. ra8_cgc_regs.h says PLL2 "has the same field layout as PLL1
//! except the multiplier is 8 bits (vs 9)", and then defines
//! k_ra8_pll2ccr_mask_quarters as 0x7FF, the same eleven-bit (mul * 4) field
//! PLL1 uses. The mask is what ra8_cgc_usb.c actually writes through, so the
//! mask is what this follows: nothing here narrows the field on the strength
//! of the prose, because inventing a reserved bit would make a multiplier read
//! back wrong for no evidence at all.
//!
//! TWO RULES, BOTH FROM THE FIRMWARE'S OWN NOTES. The stop barrier is the
//! caller's to check, because only the bus side can see OSCSF; what lives here
//! is the decision that follows. The prohibited divider is entirely this
//! file's: the bit pattern 0000 in any of PLODIVP, PLODIVQ or PLODIVR is
//! "Setting prohibited" (HUM Ch 9.2.7 for PLL1, Ch 9.2.10/9.2.12 for PLL2),
//! and ra8_cgc_regs.h records the consequence in so many words: the entire
//! 16-bit register write is dropped and the register keeps its previous value.
//! So CCR2 takes the whole word or none of it.
const div = @import("pll_div.zig");
const lanes = @import("../lanes.zig");

/// One PLL's two configuration words and what the run did to them.
pub const Config = struct {
    /// PLLmCCR: input divider, source select and the packed multiplier.
    ccr: u32 = 0,
    /// PLLmCCR2: the three output divider codes.
    ccr2: u16 = 0,
    /// Stores that landed.
    stores: u32 = 0,
    /// Stores dropped because the PLL was still running.
    dropped_running: u32 = 0,
    /// CCR2 stores rejected whole for carrying a prohibited divider code.
    prohibited_divider: u32 = 0,

    pub fn quiet(self: Config) bool {
        return self.stores == 0 and self.dropped_running == 0 and
            self.prohibited_divider == 0;
    }

    /// Whether firmware has configured this PLL at all, which is what decides
    /// if the report has anything to say about it.
    pub fn configured(self: Config) bool {
        return self.ccr != 0 or self.ccr2 != 0;
    }

    pub fn source(self: Config) div.Source {
        return div.sourceOf(self.ccr);
    }

    pub fn multiplier(self: Config) div.Multiplier {
        return div.multiplierOf(self.ccr);
    }

    /// The input divider ratio, or null when PLIDIV carries the code the part
    /// does not define.
    pub fn inputRatio(self: Config) ?u8 {
        return div.inputRatio(div.inputCodeOf(self.ccr));
    }

    /// P, Q and R output ratios. A null entry is a field never written, which
    /// a landed store cannot leave behind.
    pub fn outputRatios(self: Config) [3]?u8 {
        const codes = div.outputCodesOf(self.ccr2);
        return .{
            div.outputRatio(codes[0]),
            div.outputRatio(codes[1]),
            div.outputRatio(codes[2]),
        };
    }

    /// A store the PLL's own barrier turned away.
    pub fn refuseRunning(self: *Config) void {
        self.dropped_running +%= 1;
    }

    pub fn storeCcr(self: *Config, at: u32, width: u3, value: u32) void {
        self.ccr = lanes.merge(self.ccr, at, width, value);
        self.stores +%= 1;
    }

    /// CCR2 takes the whole word or none of it: one prohibited field and
    /// silicon drops the write and keeps what was there. Judged on the MERGED
    /// word, because that is the value the register would take.
    pub fn storeCcr2(self: *Config, at: u32, width: u3, value: u32) void {
        const written: u16 = @truncate(lanes.merge(self.ccr2, at, width, value));
        if (!div.outputsAllowed(written)) {
            self.prohibited_divider +%= 1;
            return;
        }
        self.ccr2 = written;
        self.stores +%= 1;
    }
};
