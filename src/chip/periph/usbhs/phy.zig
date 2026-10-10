//! The controller's power and port side: whether it is on, whose role it is
//! playing, and what the port reset settled on.
//!
//! dev answered the host's registers whatever SYSCFG said, and reported the
//! PHY PLL locked from the first read, so an image that never turned the
//! module or its clock on enumerated a device in the emulator and did nothing
//! on the bench. The machine here has to be brought up the way silicon is.
//!
//! The PHY behind the switch is not here: PHYSET, LPSTS and the PLL lock
//! they earn live in pll.zig. The split is the driver's own, because
//! the PHY comes up before SYSCFG.USBE does.
//!
//! A LINE STATE IS EARNED, NOT ASSUMED. Being powered and having something
//! plugged in is not enough for the host to SEE it, and the driver's own
//! bring-up says so twice, in the two comments that name the two bits:
//!
//!   SYSCFG.CNEN, the single-ended receiver (ra8_usb_irq.c, internal_host_
//!   hs_bringup): "CNEN (single-ended receiver enable) is required for the
//!   HS PHY to report line state / attach at all -- without it LNST reads
//!   SE0 forever and no ATTCH ever latches (HUM Ch 37.2.1 p 2062)."
//!
//!   DVSTCTR0.VBUSEN, the jack's external VBUS switch (same file, the HS
//!   branch of the host init): "the USBHS jack's external VBUS switch is
//!   driven by this bit (FSP hw_usb_hmodule_init); without it an attached
//!   device never powers and LNST stays SE0."
//!
//! Neither bit was named anywhere in this tree, so LNST answered J-state
//! from the moment the module was on with something attached. That is the
//! wrong direction to be wrong in: ra8_usb_hmsc_enum's attach hunt breaks
//! out of its 50-million-iteration spin the instant line_state is non-zero,
//! so a host image that forgot either bit enumerated a device here and sat
//! through the whole spin and its timeout on the bench. Both are gates on
//! the same answer now, and a reset cannot settle a speed the port could
//! not have observed either.
//!
//! THE DEVICE SIDE HAS ITS OWN TWO GATES, and they are not the same pair.
//! The previous slice left them out as NOT MODELLED because nothing found
//! then described them; ra8_usb_device.c does, at length, so they are in:
//!
//!   SYSCFG.CNEN again, quoting HUM Ch 37.2.1 p 2062 directly: "In device
//!   controller mode, set this bit to 1 when VBUS is detected because of a
//!   VBUS interrupt, and set it to 0 when the VBUS line is removed."
//!   Without it "the HS PHY's single-end receivers are powered down and
//!   SYSSTS0.LNST[1:0] reads 00b (SE0) regardless of what the host's
//!   pull-down arrangement and the device's DPRPU pull-up are doing on the
//!   wires."
//!
//!   SYSCFG.DPRPU, the device's own 1.5k pull-up on D+. It is what puts the
//!   line in J-state in the first place, and ra8_usb_device_attach writes
//!   CNEN BEFORE it "so the receivers latch the line state the moment DPRPU
//!   pulls D+ high" (HUM Ch 37.3.3 Figure 37.2 p 2121).
//!
//! So: host role needs CNEN and VBUSEN, device role needs CNEN and DPRPU,
//! and the one bit both roles share is the receiver. VBUSEN stays out of
//! the device path because a device does not own the jack's switch, and
//! DPRPU stays out of the host path for the mirror reason.
//!
//! STILL NOT MODELLED, AND NOT GUESSED: the FS instance has no CNEN gate at
//! all (ra8_usb_device.c, citing HUM Ch 36.2.1 p 1966), so on a part with
//! the FS controller these gates are one bit too many. This model is the HS
//! instance and has no FS one, so there is nothing to branch on yet.
const regs = @import("regs.zig");

/// What the port settled on after a reset, which is what DVSTCTR0.RHST
/// reports and what a driver picks its packet sizes from.
pub const Speed = enum {
    none,
    full,
    high,

    pub fn rhst(self: Speed) u16 {
        return switch (self) {
            .none => 0,
            .full => regs.port.rhst_full,
            .high => regs.port.rhst_high,
        };
    }
};

/// The power machine: SYSCFG, the PLL, the line state and the reset edge.
pub const Phy = struct {
    syscfg: u16 = 0,
    dvstctr0: u16 = 0,
    /// Whether anything is on the far end of the modelled cable.
    attached: bool = false,
    /// The speed the last completed reset settled on; none until one runs.
    speed: Speed = .none,
    /// Port resets the host drove to completion.
    resets: u32 = 0,

    /// Accesses refused, each for its own reason.
    off: u32 = 0,
    not_host: u32 = 0,
    read_only: u32 = 0,
    /// Line-state reads answered SE0 with a device on the far end, because
    /// the receiver was off or the port was unpowered. Not a refusal: the
    /// read is honest, the firmware simply cannot see what is there.
    blind: u32 = 0,

    /// The module is on and clocked. Everything but SYSCFG itself is gated on
    /// this, or the firmware could never turn it on.
    pub fn powered(self: *const Phy) bool {
        return self.syscfg & regs.syscfg.usbe != 0 and self.clocked();
    }

    /// Just the module clock. The PHY PLL runs off this alone: the driver
    /// will not set USBE until it has seen the lock, so asking for USBE
    /// here would be asking for something that cannot happen yet. The HS
    /// instance has no SCKE (HUM Ch 37.2.1 p 2060, quoted in ra8_usb_phy.c):
    /// its clock is MSTPB12 and USB60CLK, which the module-stop and clock
    /// models own. So nothing in SYSCFG gates it, and a driver that never
    /// writes bit 10 still gets a PLL once its PHYSET/LPSTS sequence lands.
    pub fn clocked(self: *const Phy) bool {
        _ = self;
        return true;
    }

    /// DCFM: this controller is driving the bus, not answering on it. A host
    /// register means nothing while the part is in device role.
    pub fn host(self: *const Phy) bool {
        return self.syscfg & regs.syscfg.dcfm != 0;
    }

    /// CNEN: the single-ended receiver that turns the differential pair into
    /// something the controller can read a line state off. Both roles.
    pub fn receiving(self: *const Phy) bool {
        return self.syscfg & regs.syscfg.cnen != 0;
    }

    /// DPRPU: the device's own pull-up on D+, which is what holds the line
    /// in J-state for the host to see. Device role only.
    pub fn pullingUp(self: *const Phy) bool {
        return self.syscfg & regs.syscfg.dprpu != 0;
    }

    /// VBUSEN: the jack's external VBUS switch. An unpowered device holds
    /// neither line up, so the pair reads SE0 whatever is plugged in.
    pub fn supplying(self: *const Phy) bool {
        return self.dvstctr0 & regs.port.vbusen != 0;
    }

    /// Whether the controller can observe the far end at all: the receiver
    /// in either role, plus the jack's switch as a host or its own pull-up
    /// as a device.
    pub fn sees(self: *const Phy) bool {
        if (!self.powered() or !self.receiving()) return false;
        return if (self.host()) self.supplying() else self.pullingUp();
    }

    /// The line state is the cable's to report, not the driver's to set, and
    /// only a port that is powered and listening reports one.
    pub fn lineState(self: *Phy) u16 {
        if (!self.sees()) {
            if (self.attached and self.powered()) self.blind += 1;
            return 0;
        }
        if (!self.attached) return 0;
        return regs.port.lnst_j;
    }

    pub fn portStatus(self: *const Phy) u16 {
        return (self.dvstctr0 & ~regs.port.rhst_mask) | self.speed.rhst();
    }

    pub fn setSyscfg(self: *Phy, value: u16) void {
        // Bit 10 is SCKE on USBFS and nothing here: a store to it is a no-op.
        self.syscfg = value & ~regs.syscfg.scke;
        if (!self.powered()) {
            self.speed = .none;
            self.dvstctr0 &= ~regs.port.uact;
        }
    }

    /// A reset ends when the host releases USBRST, and only then does the
    /// port know its speed. dev never watched the edge at all on this side.
    pub fn setPort(self: *Phy, value: u16) bool {
        if (!self.powered()) {
            self.off += 1;
            return false;
        }
        if (!self.host()) {
            self.not_host += 1;
            return false;
        }
        const was = self.dvstctr0 & regs.port.usbrst != 0;
        const now = value & regs.port.usbrst != 0;
        self.dvstctr0 = value;
        if (was and !now) self.finishReset();
        return true;
    }

    /// A reset settles on a speed only for a device the port could actually
    /// observe through it; chirping is line state like any other.
    fn finishReset(self: *Phy) void {
        self.resets += 1;
        self.speed = if (self.attached and self.sees()) .high else .none;
    }

    /// A status register a store cannot reach. SYSSTS0 is the line, RHST is
    /// what the reset found; dev let both be written and read back.
    pub fn refuseStatus(self: *Phy) void {
        self.read_only += 1;
    }

    pub fn quiet(self: *const Phy) bool {
        return self.resets == 0 and self.refusals() == 0 and self.blind == 0;
    }

    pub fn refusals(self: *const Phy) u32 {
        return self.off + self.not_host + self.read_only;
    }
};
