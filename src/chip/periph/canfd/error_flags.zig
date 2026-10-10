//! CFDCnERFL: the channel's error flags, and why a store can only clear one.
//!
//! The register sits at +0x00C inside each channel's control block
//! (ra8_canfd_regs.h, `r_canfd_cfdc_t`). Its low fifteen bits are the error
//! flags the controller raises, BEF through ADERR, and bits [30:16] are
//! CRCREG, the CRC of the last frame, which is read-only.
//!
//! THE FLAGS ARE WRITE-ZERO-TO-CLEAR, the same opposite-way-round rule
//! iwdt/status.zig keeps for IWDTSR and lvd.zig for PVDmSR.DET. The driver
//! states it and depends on it (`ra8_canfd.c` ra8_canfd_clear_status):
//!
//!     /* HUM Ch 41 p 2772 "CFDCnERFL" -- error flags are W0C: writing 0
//!      * clears, writing 1 leaves untouched. */
//!     reg->CFDC[0].ERFL = reg->CFDC[0].ERFL & ~mask;
//!
//! So a store can lower a flag and can never raise one. A store is not how
//! an error happens; the controller is.
//!
//! WHY IT MATTERS HERE. ERFL was not interpreted at all, so it fell into the
//! flat shadow: whatever firmware wrote at it read straight back as standing
//! error flags. The way in is the acknowledgement convention. Most CAN parts
//! clear a status flag by writing a one, this header's own constant is
//! misnamed `k_ra8_cnerfl_mask_all_w1c`, and a driver that acks that way
//! wrote 0x7FFF and SET all fifteen flags here. They then stay: the RA8
//! driver's own clear is a read-modify-write of the inverse mask
//! (`ERFL & ~mask`), so clearing BEF writes 0x7FFE back and every other flag
//! survives its own acknowledgement. `ra8_canfd_dispatch` snapshots ERFL and
//! hands that word to the application's event callback, so an image running
//! a clean internal loopback is told its bus went error-passive, lost
//! arbitration and bit-stuffed. Writing ones cannot raise a flag now, and
//! the store is counted so a run says a driver tried.
//!
//! This is the same rule the block header already states for CFDRFSTS and
//! CFDTMSTS ("STATUS IS WHAT THE CONTROLLER RAISED"), reaching the one
//! status register the driver is supposed to write.
//!
//! NOT MODELLED, AND NOT GUESSED: anything that raises a flag. There is no
//! bus and no second node here, so no frame can be NAKed, no arbitration
//! lost and no bit mis-stuffed; the flags stay down and the run says so
//! rather than inventing traffic. CRCREG is left at zero for the same
//! reason: no CRC is computed over the loopback frame.
const lanes = @import("../lanes.zig");

/// Where the register sits inside a channel window, and which bits are what.
pub const off: u32 = 0x00C;

pub const mask = struct {
    /// [14:0]: BEF, EWF, EPF, BOEF, BORF, OVLF, BLF, ALF, SERR, FERR,
    /// AERR, CERR, B1ERR, B0ERR, ADERR.
    pub const flags: u32 = 0x0000_7FFF;
    /// [30:16] CRCREG, the CRC of the last frame. Read-only.
    pub const crc: u32 = 0x7FFF_0000;
};

/// One channel's error flags.
pub const Errors = struct {
    /// The flags standing right now. Nothing in this model raises one.
    flags: u32 = 0,
    /// Stores that would have raised a flag the controller never saw.
    invented: u32 = 0,

    pub fn quiet(self: *const Errors) bool {
        return self.flags == 0 and self.invented == 0;
    }

    /// What a read of the register answers. CRCREG reads zero: no CRC is
    /// computed here, and a made-up one would be worse than none.
    pub fn read(self: *const Errors) u32 {
        return self.flags & mask.flags;
    }

    /// A store. Only the lanes the access names are touched, so a byte
    /// store clears the flags in its own byte and leaves the rest standing.
    /// A zero at a standing flag lowers it; a one leaves it where it was.
    pub fn store(self: *Errors, lane: u32, width: u3, value: u32) void {
        const named = lanes.named(lane, width) & mask.flags;
        const carried = value & named;
        if (carried & ~self.flags != 0) self.invented +%= 1;
        self.flags &= ~(named & ~carried);
    }
};
