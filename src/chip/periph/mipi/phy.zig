//! MIPI D-PHY: the physical layer under DSI and CSI, so its init sequence
//! can end.
//!
//! The block is one window at 0x4034_6C00 (ra8_glcdc_regs.h,
//! k_ra8_mipi_phy_base_addr, between MIPI DSI at 0x4034_6000 and MIPI CSI at
//! 0x4034_7000). Nothing modelled it, so every access fell through to the
//! sparse register file, and that had teeth: DPHYSFR is read-only status the
//! firmware never writes, so the sparse file handed back zero forever.
//! ra8_mipi_phy.c spins on it twice in one init, through
//! internal_mipi_phy_wait_set with a 4096-poll budget, once for PWRSF after
//! it powers the LDO and once for PLLSF after it clears PLLSTP. Both burned
//! their whole budget and returned a hardware timeout, so ra8_mipi_phy_init
//! reported "LDO did not stabilise" on a part that was working, and every
//! display and camera bring-up behind it stopped at that line.
//!
//!   DPHYREFCR  (+0x000)  reference clock, RFREQ[7:0] = MHz - 1
//!   DPHYPLFCR  (+0x004)  PLL frequency: IDIV, NFMUL, PMUL, NMUL
//!   DPHYPLOCR  (+0x008)  PLL operation, PLLSTP
//!   DPHYESCCR  (+0x00C)  escape clock divider
//!   DPHYPWRCR  (+0x010)  LDO supply, PWRSEN
//!   DPHYSFR    (+0x01C)  status flags, read-only, derived here
//!   DPHYOCR    (+0x020)  D-PHY enable, DPHYEN
//!   DPHYTIM1-6 (+0x024..+0x038)  lane timing
//!   DPHYMDC    (+0x048)  host (DSI) or device (CSI)
//!
//! DPHYSFR IS READ-ONLY AND DERIVED. A store to it is refused and counted,
//! the line ACMPHS draws around CMPMON and the RTC file draws around R64CNT.
//! What it reads comes from src/chip/periph/mipi/phy_status.zig, which carries the
//! rule and states what it does not model.
//!
//! THE PLL COMES OUT OF RESET STOPPED, AND ITS COEFFICIENTS ARE LOCKED WHILE
//! IT RUNS. DPHYPLOCR.PLLSTP reads 1 after reset (HUM Ch 64.2.3 p 3824,
//! quoted in ra8_mipi_phy_regs.h), and DPHYPLFCR and DPHYESCCR only take a
//! store while it does. Both halves live in src/chip/periph/mipi/phy_pll_lock.zig
//! with the citations; the consequence here is that the lock flag comes up on
//! the DPHYPLOCR write that ENDS the host sequence, which is the write the
//! driver then spins on DPHYSFR for, and not on the DPHYPLFCR write three
//! steps earlier.
//!
//! NOT MODELLED, AND NOT GUESSED: the lanes themselves. Timing, escape clock
//! divider and reference frequency are stored, read back and never
//! interpreted, because nothing in this tree carries a lane-level model for
//! them to drive. The PHY's own interrupt is the same: ra8_mipi_phy_dispatch
//! edge-detects DPHYSFR in software off whatever vector called it, and no ELC
//! number for the PHY is in either tree, so nothing is raised here.
const periph = @import("../registry.zig");
const status = @import("phy_status.zig");
const pll_lock = @import("phy_pll_lock.zig");

/// D-PHY geometry. The bus folds the Non-secure alias onto this base.
pub const win_base: u32 = 0x4034_6C00;
pub const win_span: u32 = 0x4C;

/// The status rule, re-exported so callers reach it through this block.
pub const flags = status;

pub const off = struct {
    pub const refcr: u32 = 0x000;
    pub const plfcr: u32 = 0x004;
    pub const plocr: u32 = 0x008;
    pub const esccr: u32 = 0x00C;
    pub const pwrcr: u32 = 0x010;
    pub const sfr: u32 = 0x01C;
    pub const ocr: u32 = 0x020;
    pub const tim1: u32 = 0x024;
    pub const tim6: u32 = 0x038;
    pub const mdc: u32 = 0x048;
};

/// The PHY: the registers this model interprets, a shadow for the rest of
/// the window, and what the run should be told about it.
pub const MipiPhy = struct {
    refcr: u32 = 0,
    plfcr: u32 = 0,
    /// Reset value: the PLL is stopped until firmware releases it.
    plocr: u32 = pll_lock.plocr_reset,
    esccr: u32 = 0,
    pwrcr: u32 = 0,
    ocr: u32 = 0,
    mdc: u32 = 0,
    /// DPHYTIM1..6, kept in order so a read-modify-write survives.
    timing: [6]u32 = @splat(0),
    /// Every other word in the window.
    shadow: [win_span]u8 = @splat(0),
    /// Reads of DPHYSFR, which is how the driver waits.
    polls: u32 = 0,
    /// Reads of DPHYSFR that found nothing latched.
    dark_polls: u32 = 0,
    /// Stores aimed at DPHYSFR, which is read-only.
    refused: u32 = 0,
    /// Times the LDO was switched on.
    powerups: u32 = 0,
    /// Times the PLL went from not locked to locked.
    locks: u32 = 0,
    /// Times DPHYOCR.DPHYEN went from clear to set.
    enables: u32 = 0,
    /// Stores to DPHYPLFCR or DPHYESCCR dropped because the PLL was running.
    pll: pll_lock.Locked = .{},
    /// Enables taken with DPHYSFR not ready: lanes started before the PHY
    /// said it was stable, which on a bench is a link that comes up
    /// intermittently rather than not at all.
    early_enables: u32 = 0,

    pub fn init() MipiPhy {
        return .{};
    }

    pub fn quiet(self: *const MipiPhy) bool {
        return self.polls == 0 and self.dark_polls == 0 and self.refused == 0 and
            self.powerups == 0 and self.enables == 0 and self.pll.quiet();
    }

    pub fn mode(self: *const MipiPhy) status.Mode {
        return status.Mode.of(self.mdc);
    }

    /// DPHYSFR as it stands right now, without counting a read.
    pub fn sfr(self: *const MipiPhy) u32 {
        return status.value(self.pwrcr, self.plocr, self.plfcr);
    }

    pub fn ready(self: *const MipiPhy) bool {
        return status.ready(self.sfr());
    }

    pub fn driving(self: *const MipiPhy) bool {
        return status.enabled(self.ocr);
    }

    /// The reference clock the firmware declared, in MHz. RFREQ encodes
    /// MHz - 1, so a zero register is 1 MHz and not "unset"; quiet() is what
    /// says whether the block was used at all.
    pub fn referenceMhz(self: *const MipiPhy) u32 {
        return (self.refcr & 0xFF) + 1;
    }

    /// A read of DPHYSFR, counted by what it found.
    fn poll(self: *MipiPhy) u32 {
        const value = self.sfr();
        if (value == 0) self.dark_polls +%= 1 else self.polls +%= 1;
        return value;
    }

    fn timingIndex(local: u32) ?usize {
        if (local < off.tim1 or local > off.tim6) return null;
        return (local - off.tim1) / 4;
    }

    fn readWord(self: *MipiPhy, local: u32) u32 {
        return switch (local) {
            off.refcr => self.refcr,
            off.plfcr => self.plfcr,
            off.plocr => self.plocr,
            off.esccr => self.esccr,
            off.pwrcr => self.pwrcr,
            off.sfr => self.poll(),
            off.ocr => self.ocr,
            off.mdc => self.mdc,
            else => if (timingIndex(local)) |index| self.timing[index] else self.shadowWord(local),
        };
    }

    /// Every control write goes through here, so the PLL lock is counted on
    /// the edge wherever it happens. On the host path that edge is the
    /// DPHYPLOCR write the sequence ends with: PLLSTP reads 1 out of reset,
    /// so the coefficients written three steps earlier cannot latch a lock on
    /// their own.
    fn writeWord(self: *MipiPhy, local: u32, value: u32) void {
        const was_locked = self.sfr() & status.flag.pllsf != 0;
        self.applyWord(local, value);
        if (!was_locked and self.sfr() & status.flag.pllsf != 0) self.locks +%= 1;
    }

    fn applyWord(self: *MipiPhy, local: u32, value: u32) void {
        switch (local) {
            off.refcr => self.refcr = value,
            off.plfcr => if (self.pll.takes(self.plocr)) {
                self.plfcr = value;
            },
            off.plocr => self.plocr = value,
            off.esccr => if (self.pll.takes(self.plocr)) {
                self.esccr = value;
            },
            off.pwrcr => self.setPower(value),
            // Read-only: the PHY owns this one.
            off.sfr => self.refused +%= 1,
            off.ocr => self.setOperation(value),
            off.mdc => self.mdc = value,
            else => if (timingIndex(local)) |index| {
                self.timing[index] = value;
            } else self.setShadowWord(local, value),
        }
    }

    fn setPower(self: *MipiPhy, value: u32) void {
        if (!status.supplied(self.pwrcr) and status.supplied(value)) self.powerups +%= 1;
        self.pwrcr = value;
    }

    fn setOperation(self: *MipiPhy, value: u32) void {
        if (!status.enabled(self.ocr) and status.enabled(value)) {
            self.enables +%= 1;
            if (!self.ready()) self.early_enables +%= 1;
        }
        self.ocr = value;
    }

    fn shadowWord(self: *const MipiPhy, local: u32) u32 {
        var value: u32 = 0;
        var index: u32 = 0;
        while (index < 4 and local + index < win_span) : (index += 1) {
            const shift: u5 = @intCast(index * 8);
            value |= @as(u32, self.shadow[local + index]) << shift;
        }
        return value;
    }

    fn setShadowWord(self: *MipiPhy, local: u32, value: u32) void {
        var index: u32 = 0;
        while (index < 4 and local + index < win_span) : (index += 1) {
            const shift: u5 = @intCast(index * 8);
            self.shadow[local + index] = @truncate(value >> shift);
        }
    }

    /// Every register here is a 32-bit word, so a narrower access is served
    /// out of the word it lands in rather than pretending the window is a
    /// byte array.
    pub fn read(self: *MipiPhy, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        if (offset >= win_span) return 0;
        const word = offset & ~@as(u32, 3);
        const shift: u5 = @intCast((offset & 3) * 8);
        const value = self.readWord(word) >> shift;
        return switch (width) {
            1 => value & 0xFF,
            2 => value & 0xFFFF,
            else => value,
        };
    }

    pub fn write(self: *MipiPhy, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        if (offset >= win_span) return;
        const word = offset & ~@as(u32, 3);
        if (width == 4 and offset == word) {
            self.writeWord(word, value);
            return;
        }
        const shift: u5 = @intCast((offset & 3) * 8);
        const mask: u32 = switch (width) {
            1 => @as(u32, 0xFF) << shift,
            2 => @as(u32, 0xFFFF) << shift,
            else => 0xFFFF_FFFF,
        };
        const merged = (self.readWordQuiet(word) & ~mask) | ((value << shift) & mask);
        self.writeWord(word, merged);
    }

    /// The same read the bus would do, without counting a DPHYSFR poll: a
    /// byte store into a word is not firmware reading status.
    fn readWordQuiet(self: *MipiPhy, local: u32) u32 {
        if (local == off.sfr) return self.sfr();
        return self.readWord(local);
    }

    pub fn block(self: *MipiPhy) periph.Block {
        return .{
            .name = "MIPI-PHY",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *MipiPhy = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *MipiPhy = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
