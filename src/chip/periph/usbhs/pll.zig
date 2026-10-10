//! The USB high-speed PHY's own PLL: the two registers that bring the
//! analog block up, and the lock flag the driver spins on before it will
//! touch anything else.
//!
//! This is not the module's power switch, which is SYSCFG and lives in
//! phy.zig. It is the PHY behind it: PHYSET holds the analog
//! power-down and the PLL reset, LPSTS gates the PHY clock, and PLLSTA
//! reports whether the UTMI PLL has settled. The order matters, and it is
//! the driver's, not this model's: ra8_usb_phy.c's internal_usbhs_try_clksel
//! drops SUSPENDM, asserts DIRPD and PLLRESET together with a CLKSEL
//! codepoint, releases DIRPD, waits a millisecond, releases PLLRESET, sets
//! SUSPENDM, and only then polls PLLSTA.
//!
//! Two things follow that this model has to honour. The lock cannot depend
//! on SYSCFG.USBE, because HUM Figure 37.2 (p 2121, quoted in that driver)
//! puts USBE *after* the lock is observed: a model that waits for USBE waits
//! for something the driver will not do until the model answers. And it
//! cannot be free either, or the whole sequence above is ceremony: a run
//! that never powers the analog block gets a locked PLL and reports a PHY
//! that came up when on the bench it never would have.
const regs = @import("regs.zig");

/// The PHY machine: what PHYSET and LPSTS hold, and whether the PLL has
/// settled on top of them.
pub const Pll = struct {
    /// PHYSET. It comes up powered down with the PLL held in reset, so a
    /// run that writes nothing here has no PHY. Only the CLKSEL field's
    /// reset value is sourced (11b, 24 MHz, named in ra8_usb_regs.h); the
    /// two reset bits coming up asserted is this model's own choice, and
    /// the driver does not lean on it either way because its own sequence
    /// asserts both before releasing them.
    physet: u16 = regs.physet.dirpd | regs.physet.pllreset | regs.physet.clksel_24,
    /// LPSTS. SUSPENDM low: the PHY clock is not oscillating yet.
    lpsts: u16 = 0,
    /// Whether the PLL is settled right now.
    locked: bool = false,

    /// Times the PLL went from unsettled to locked.
    locks: u32 = 0,
    /// PLLSTA reads answered unlocked. A driver polling a PHY it never
    /// brought up spends its whole budget here.
    stalled: u32 = 0,

    pub fn quiet(self: *const Pll) bool {
        return self.locks == 0 and self.stalled == 0;
    }

    /// Everything the PLL needs to be running: the module's clock (always
    /// there on HS, see Phy.clocked), the analog block powered, the PLL out of reset, and the
    /// PHY clock oscillating.
    fn ready(self: *const Pll, clocked: bool) bool {
        return clocked and
            self.physet & regs.physet.dirpd == 0 and
            self.physet & regs.physet.pllreset == 0 and
            self.lpsts & regs.lpsts.suspendm != 0;
    }

    /// Re-judge the lock after something that could have changed it.
    fn settle(self: *Pll, clocked: bool) void {
        const now = self.ready(clocked);
        if (now and !self.locked) self.locks += 1;
        self.locked = now;
    }

    pub fn setPhyset(self: *Pll, value: u16, clocked: bool) void {
        self.physet = value;
        self.settle(clocked);
    }

    pub fn setLpsts(self: *Pll, value: u16, clocked: bool) void {
        self.lpsts = value;
        self.settle(clocked);
    }

    /// SYSCFG moved under us, so the module clock may have come or gone.
    pub fn clockChanged(self: *Pll, clocked: bool) void {
        self.settle(clocked);
    }

    /// What PLLSTA answers. The lock is re-judged on the read too, so a
    /// poll cannot be served a stale answer by a store this model missed.
    pub fn status(self: *Pll, clocked: bool) u16 {
        self.settle(clocked);
        if (!self.locked) {
            self.stalled += 1;
            return 0;
        }
        return regs.pllsta.plllock;
    }
};
