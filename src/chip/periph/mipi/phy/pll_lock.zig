//! DPHYPLOCR.PLLSTP: the D-PHY PLL's stop bit, and the two registers that
//! only take a store while it is set.
//!
//! Its own file rather than a prong inside phy.zig, the way
//! spi/enable_lock.zig sits beside spi.zig, because two separate HUM rules
//! land on the same bit and both are easy to lose in a switch arm.
//!
//! THE RESET VALUE IS THE FIRST HALF OF THE RULE. ra8_mipi_phy_regs.h, citing
//! HUM Ch 64.2.3 "DPHYPLOCR : D-PHY PLL Operation Control Register" p 3824,
//! says in so many words: "bit 0 = PLLSTP (0 = run PLL, 1 = stop PLL).
//! Reset = 1." The PLL comes out of reset STOPPED. A model that starts it
//! running reports a lock the part has not taken, and hands the coefficient
//! registers below a window they should never have had.
//!
//! THE WRITE GATE IS THE SECOND HALF, and the driver quotes it twice:
//!
//!   DPHYPLFCR   ra8_mipi_phy_ops.h:46, HUM Ch 64.2.2 p 3824, "DPHYPLFCR may
//!               only be written while DPHYPLOCR.PLLSTP = 1"; ra8_mipi_phy.c
//!               repeats it at ra8_mipi_phy_set_lane_speed as "DPHYPLFCR must
//!               be set while D-PHY PLL operation is stopped".
//!   DPHYESCCR   ra8_mipi_phy_ops.h:297, HUM Ch 64.2.4 p 3825, "ESCDIV[4:0]
//!               must be written while DPHYPLOCR.PLLSTP = 1".
//!
//! Both driver helpers exist only to enforce it: set_lane_speed and
//! set_escape_divisor each stop the PLL, store, then release it and spin on
//! DPHYSFR.PLLSF. That is the whole reason they are not plain register
//! writes, so a model that takes the store either way makes them pointless
//! and lets an image that skips the stop pass here and fail on the bench.
//!
//! WHAT IS NOT MODELLED, AND NOT GUESSED: what the part does with the value
//! it refuses. Nothing in either tree says whether the write is dropped or
//! lands in a holding register that the next PLL start consumes, so this
//! takes the narrower reading and drops it. The register keeps what it had,
//! and the refusal is counted so the run can say so.
const status = @import("status.zig");

/// DPHYPLOCR out of reset: the PLL is stopped.
pub const plocr_reset: u32 = status.pll_control.pllstp;

/// The gate on the two PLL coefficient registers.
pub const Locked = struct {
    /// Stores dropped because the PLL was still running.
    ignored: u32 = 0,

    /// Does a store to DPHYPLFCR or DPHYESCCR carry? Only with the PLL
    /// stopped. A refused store is counted and changes nothing, so the
    /// driver can come back after stopping the PLL.
    pub fn takes(self: *Locked, plocr: u32) bool {
        if (status.running(plocr)) {
            self.ignored +%= 1;
            return false;
        }
        return true;
    }

    pub fn quiet(self: *const Locked) bool {
        return self.ignored == 0;
    }
};
