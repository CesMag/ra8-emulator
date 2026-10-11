//! DPHYSFR: when the D-PHY's two status flags latch, and what they mean.
//!
//! The status register is read-only silicon state. The driver never writes
//! it; it writes DPHYPWRCR and DPHYPLOCR and then spins here waiting for the
//! answer. So the rule has to live somewhere, and it lives in this file
//! rather than in the block, the same split the AGT compare rule and the
//! ACMPHS monitor rule use.
//!
//! Two flags, from ra8_mipi_phy_regs.h citing HUM Ch 64.2.6 p 3826:
//!
//!   PWRSF  (bit 0)  the D-PHY LDO has powered up and is stable
//!   PLLSF  (bit 8)  the PHY PLL has locked and its clock is stable
//!
//! WHAT IS DERIVED, AND FROM WHAT. PWRSF follows DPHYPWRCR.PWRSEN: the LDO
//! is asked for and settles, because a headless run has no analogue settling
//! time to model and the driver's own budget (4096 polls) is there for a
//! stuck part, not a slow one.
//!
//! PLLSF takes three things, all of them from the driver's own init order in
//! ra8_mipi_phy.c: the LDO has to be up (steps 1-5 run before 6-9), the PLL
//! has to be configured (step 6 writes DPHYPLFCR, and CSI device mode
//! deliberately leaves it zero because that PLL is not used), and the PLL has
//! to not be stopped (step 8 clears DPHYPLOCR.PLLSTP). An unconfigured PLL
//! reporting lock would tell a device-mode image its host clock was running.
//!
//! NOT MODELLED, AND NOT GUESSED: how long either takes. Nothing in either
//! tree carries the LDO settle time or the PLL lock time for this part, so
//! both latch on the write that asks for them. An image that measures the
//! lock time measures nothing here.

/// DPHYSFR flag masks.
pub const flag = struct {
    pub const pwrsf: u32 = 0x0000_0001;
    pub const pllsf: u32 = 0x0000_0100;
    pub const ready: u32 = pwrsf | pllsf;
};

/// DPHYPWRCR: the LDO supply switch.
pub const power = struct {
    pub const pwrsen: u32 = 0x1;
};

/// DPHYPLOCR: the PLL stop bit. Set stops the PLL, clear lets it run.
pub const pll_control = struct {
    pub const pllstp: u32 = 0x1;
};

/// DPHYOCR: the D-PHY itself.
pub const operation = struct {
    pub const dphyen: u32 = 0x1;
};

/// DPHYMDC: which end of the link this PHY is.
pub const mode_control = struct {
    pub const hosten: u32 = 0x1;
};

/// Which end of the link the PHY was told to be. Host is the DSI transmitter
/// driving a panel; device is the CSI receiver taking a camera's lanes.
pub const Mode = enum {
    device,
    host,

    pub fn of(mdc: u32) Mode {
        return if (mdc & mode_control.hosten != 0) .host else .device;
    }

    pub fn name(self: Mode) []const u8 {
        return switch (self) {
            .device => "device (CSI receiver)",
            .host => "host (DSI transmitter)",
        };
    }
};

/// Has firmware asked for the LDO?
pub fn supplied(pwrcr: u32) bool {
    return pwrcr & power.pwrsen != 0;
}

/// Is the PLL allowed to run? PLLSTP set stops it.
pub fn running(plocr: u32) bool {
    return plocr & pll_control.pllstp == 0;
}

/// Has the PLL been given a multiplier to lock onto? DPHYPLFCR resets to
/// zero, and device mode writes zero back into it on purpose.
pub fn configured(plfcr: u32) bool {
    return plfcr != 0;
}

/// Is the D-PHY driving its lanes?
pub fn enabled(ocr: u32) bool {
    return ocr & operation.dphyen != 0;
}

/// DPHYSFR as firmware reads it, from the three registers that decide it.
pub fn value(pwrcr: u32, plocr: u32, plfcr: u32) u32 {
    var sfr: u32 = 0;
    if (!supplied(pwrcr)) return sfr;
    sfr |= flag.pwrsf;
    if (running(plocr) and configured(plfcr)) sfr |= flag.pllsf;
    return sfr;
}

/// True once both flags are up, which is what ra8_mipi_phy_wait_ready spins
/// for.
pub fn ready(sfr: u32) bool {
    return sfr & flag.ready == flag.ready;
}

/// A short name for what a given DPHYSFR says, for the end-of-run line.
pub fn describe(sfr: u32) []const u8 {
    if (ready(sfr)) return "LDO stable, PLL locked";
    if (sfr & flag.pwrsf != 0) return "LDO stable, PLL not locked";
    return "LDO off";
}
