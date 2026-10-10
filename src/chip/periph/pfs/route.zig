//! The one ordering rule PmnPFS has: a pin is returned to GPIO mode before a
//! new peripheral function is programmed onto it.
//!
//! (HUM Ch 20.2.4 "Notes on the PmnPFS Register Setting" p 859.) PMR picks
//! whether the pad is a GPIO or a peripheral output, PSEL picks which
//! peripheral. Moving a routed pin straight from one function to another in a
//! single store leaves PMR standing while the new PSEL is decoded, and the pad
//! drives whatever the PREVIOUS function happened to be for as long as the
//! decode takes. The sequence the part wants is three stores:
//!
//!   1. PMR := 0             the pad goes back to GPIO
//!   2. PFS := new PSEL      the function is programmed with PMR still clear
//!   3. PFS := PSEL | PMR    the pad is handed to the peripheral
//!
//! Both drivers here already do exactly that, and say why in the same words:
//! ra8_pfs_route_peripheral in gpio.c and ra8_mpc_route_peripheral in
//! ra8_mpc.c, the latter noting that a single combined write "is what FSP
//! r_ioport_pfs_write avoids".
//!
//! THIS IS NOT A REFUSAL, AND THAT IS THE DECISION IN THIS FILE. The part
//! takes the store; what it does not do is take it cleanly. Refusing it here
//! would invent a behaviour silicon does not have and would leave the pin on
//! its old function, which is further from the bench than taking it. So the
//! store lands exactly as before and the run counts it, because the glitch is
//! invisible from the firmware side: nothing faults, nothing reads back wrong,
//! and the pin settles on the function that was asked for. An intermittent
//! spike on the old function during bring-up is the kind of thing that gets
//! blamed on the board for a week, so the report is the whole value here.
//!
//! WHAT IS NOT COUNTED, deliberately. A store that clears PMR is the sequence
//! working: `*pfs = 0` is step 1 and it changes PSEL to zero at the same time,
//! so counting "PSEL moved while PMR stood" would flag the correct driver on
//! its own first store. Only a store that LEAVES the pin in peripheral mode
//! while changing which peripheral is the prohibited one. A store that sets
//! PMR for the first time is step 3 and carries no change of function; a store
//! that changes drive strength, pull-up or direction on an already-routed pin
//! leaves PSEL alone and is untouched.

/// The two PmnPFS fields this rule is about (ra8_pfs_regs.h: PMR at bit 16,
/// PSEL at bits 28:24).
pub const field = struct {
    pub const pmr: u32 = 1 << 16;
    pub const psel: u32 = 0x1F00_0000;
};

/// Whether a pin is in peripheral mode.
pub fn routed(entry: u32) bool {
    return entry & field.pmr != 0;
}

/// Which peripheral function a pin carries.
pub fn functionOf(entry: u32) u32 {
    return (entry & field.psel) >> 24;
}

/// The count of pins handed straight from one function to another.
pub const Route = struct {
    /// Stores that moved a routed pin to a different function in one go.
    glitched: u32 = 0,

    pub fn quiet(self: Route) bool {
        return self.glitched == 0;
    }

    /// Take a landed PmnPFS store and say whether it skipped the GPIO step.
    /// Both sides must be in peripheral mode and the function must have
    /// moved; see the header for why a store that clears PMR is the sequence
    /// working rather than a breach of it.
    pub fn observe(self: *Route, standing: u32, merged: u32) void {
        if (!routed(standing) or !routed(merged)) return;
        if (functionOf(standing) == functionOf(merged)) return;
        self.glitched +%= 1;
    }
};
