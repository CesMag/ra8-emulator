//! The CAN-FD sleep request, and why a mode write can land on nothing.
//!
//! Both CAN-FD state machines carry a sleep request beside their mode field:
//! CFDGCTR.GSLPR and CFDCnCTR.CSLPR, bit 2 of each control register, with
//! CFDGSTS.GSLPSTS and CFDCnSTS.CSLPSTS reporting it back in bit 2 of the
//! matching status word (HUM Ch 41 p 2742 "CFDGCTR", p 2762 "CFDCnCTR",
//! p 2766 "CFDCnSTS").
//!
//! BOTH MACHINES COME OUT OF RESET ASLEEP, and while one is asleep a mode
//! write to it is SILENTLY IGNORED: the state machine stays where it was,
//! the status bits never flip, and the driver's poll on the new mode times
//! out several milliseconds later with nothing to say about the cause. The
//! mode field in the store is simply dropped.
//!
//! THE GATE IS ON THE VALUE THE STORE CARRIES, not on the state standing
//! before it, and that distinction is the whole of the rule. ra8_canfd.c's
//! priv_ra8_canfd_internal_set_channel_mode clears CSLPR and stamps CHMDC in
//! ONE store:
//!
//!     ctr &= ~(k_ra8_cnctr_mask_chmdc | k_ra8_cnctr_mask_cslpr);
//!     ctr |= ((uint32_t)mode & k_ra8_cnctr_mask_chmdc);
//!     reg->CFDC[0].CTR = ctr;
//!
//! That single store is the fix for the bug the same comment records, so a
//! store clearing the request must carry its mode through. A store that
//! leaves the request set carries no mode change at all.
//!
//! The evidence is first-hand and in the driver: "the channel comes out of
//! reset with CSLPR=1 (sleep request), and CHMDC writes are silently ignored
//! while the channel is asleep -- the state machine stays in CH_RESET,
//! status bits never flip, and the next mode write times out. JTAG dump
//! after the original init showed CTR=0x05 / STS=0x05 (CHMDC=01 RESET +
//! CSLPR=1 + CRSTSTS=1 + CSLPSTS=1) confirming the channel never woke."
//! CTR=0x05 is mode 1 with bit 2 set, and STS=0x05 is CRSTSTS with CSLPSTS
//! standing beside it: exactly the pair this file models.
//!
//! Without it the two drivers are indistinguishable here. The model took the
//! mode out of any store and flipped the status bits, so an image that never
//! clears the sleep request reaches operation mode in the emulator and hangs
//! on silicon, which is the masked pass this file ends.
const std = @import("std");

/// Bit 2 of the control register: GSLPR on the global machine, CSLPR on the
/// channel. Bit 2 of the status register reports it back.
pub const request: u32 = 1 << 2;
pub const status: u32 = 1 << 2;

/// One machine's sleep request. Set out of reset, as on silicon.
pub const Request = struct {
    asleep: bool = true,
    /// Mode writes dropped because the machine was asleep.
    ignored: u32 = 0,

    /// Take a control-register store. True when the mode it carries lands.
    pub fn store(self: *Request, value: u32) bool {
        const asking = value & request != 0;
        if (self.asleep and asking) {
            self.ignored +%= 1;
            return false;
        }
        self.asleep = asking;
        return true;
    }

    /// What the status register adds for this machine.
    pub fn statusBit(self: *const Request) u32 {
        return if (self.asleep) status else 0;
    }
};

/// The pair a controller owns, so the block carries one field rather than
/// two and the report can ask about both at once.
pub const Pair = struct {
    global: Request = .{},
    channel: Request = .{},

    pub fn quiet(self: *const Pair) bool {
        return self.global.ignored == 0 and self.channel.ignored == 0;
    }

    /// Mode writes dropped across both machines.
    pub fn ignored(self: *const Pair) u32 {
        return self.global.ignored +% self.channel.ignored;
    }
};
