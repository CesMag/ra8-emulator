//! RCR4.RCKSEL, the RTC count source, and the one ordering rule the driver's
//! own bring-up depends on.
//!
//! RCR4 sits at +0x28 in the RTC window (ra8_rtc_regs.h, which also records
//! that there is no RCR3 on this part and that +0x26 is reserved). Bit 0 is
//! RCKSEL: 0 selects the 32.768 kHz sub-clock crystal, 1 the internal LOCO
//! (ra8_rtc.h, k_ra8_rtc_clk_subclock and k_ra8_rtc_clk_loco, which the
//! driver stores into the register unchanged).
//!
//! The whole register was a plain shadow here: a store landed, a load read
//! it back, and nothing else. So a run could not say which source the
//! firmware had picked, and could not tell a bring-up that picked one from
//! a bring-up that never did.
//!
//! THE RULE. ra8_rtc_clock_init writes RCR4 first, before anything else in
//! the block, and says why: "HUM Ch 26.2.23 RCR4 p 1236 -- RCKSEL selects
//! the count source. It must be set once before the initial RTC register
//! settings." The initial settings end at the software reset, which the
//! same function reaches last and which "initializes the prescaler and
//! count registers against the live count source" (HUM Ch 26.2.21 p 1233).
//! So the reset is the boundary this model can see: a source selected
//! before it is the driver's order, and a source selected after it is a
//! source swapped under a prescaler already initialised against the other
//! one.
//!
//! COUNTED, NOT REFUSED, the same discipline frequency.zig states for
//! its own two rules: the manual page in this tree names the precondition
//! and does not say what the part does to a driver that ignores it, and
//! inventing a refusal would put words in its mouth. The byte still lands.
//!
//! NOT MODELLED, AND NOT GUESSED: the six-clock settle. ra8_rtc.c waits
//! k_ra8_rtc_clk_six_clocks_ms after the RCKSEL store because HUM Ch 26.3.2
//! p 1243 asks for at least six clocks of the count source, but this model
//! counts a second of its own rather than running a 32.768 kHz source, so
//! it has no clock to count six of. The bits above RCKSEL stay shadow too:
//! the header calls the register "count source / mode" and gives no
//! encoding for a mode field.

/// Bit 0 of RCR4, the count source select.
pub const rcksel: u8 = 0x01;

/// What RCKSEL picks (ra8_rtc.h).
pub const Source = enum(u1) {
    subclock = 0,
    loco = 1,

    pub fn name(self: Source) []const u8 {
        return switch (self) {
            .subclock => "sub-clock",
            .loco => "LOCO",
        };
    }
};

/// The count source the run was given, and what it made of the order.
pub const Select = struct {
    /// Whether RCKSEL has been written at all.
    chosen: bool = false,

    /// What the last store selected. Reset leaves the sub-clock selected,
    /// which is RCKSEL's own reset value.
    source: Source = .subclock,

    /// Whether the initial register settings are in, which this model reads
    /// as the software reset having been performed.
    settled: bool = false,

    /// RCKSEL stores that landed after the initial settings were in.
    late: u32 = 0,

    /// Software resets asked for with no count source ever selected.
    unsourced: u32 = 0,

    /// Take an RCR4 store. The byte lands either way; this only judges it.
    pub fn select(self: *Select, byte: u8) void {
        if (self.settled) self.late +%= 1;
        self.source = if (byte & rcksel != 0) .loco else .subclock;
        self.chosen = true;
    }

    /// The software reset that ends the initial settings.
    pub fn initialise(self: *Select) void {
        if (!self.chosen) self.unsourced +%= 1;
        self.settled = true;
    }

    /// Nothing worth a line in the report.
    pub fn quiet(self: *const Select) bool {
        return !self.chosen and self.late == 0 and self.unsourced == 0;
    }
};
