//! The low-power control registers the reset path restores: SBYCR, DPSBYCR
//! and LPSCR, all three write-protected behind PRCR.PRC1.
//!
//! These three were the next most-written addresses in the EIL corpus that
//! nothing modelled: 32 of the 36 images write all three, always the same
//! values in the same order. They come from ra8_lpm_safe_boot() in
//! ra8_lpm_safe_boot.h, an always-inline helper the reset handler runs before
//! .data and .bss are up. It unlocks PRC1 with 0xA502, writes LPSCR = 0,
//! SBYCR = 0x40, DPSBYCR = 0x14, then relocks with 0xA500. The point of it is
//! stated in the header: with LPMD left at whatever a warm reset left behind,
//! the next plain WFI can enter Software Standby instead of Sleep, so the
//! reset path puts the three registers back to their cold-reset values before
//! any driver runs.
//!
//!   SBYCR   (0x4001_E00C, 8b)  OPE bit 6, and nothing else software-writable
//!   DPSBYCR (0x4001_EA00, 8b)  IOKEEP bit 6, DCSSMODE bits 3:2, bit 4 reads 1
//!   LPSCR   (0x4001_EA90, 8b)  LPMD bits 3:0
//!
//! Offsets, widths, reset values and field positions are all from
//! libs/ra8_hal/inc/ra8_lpm_regs.h on zig/dev, which cites HUM Ch 11.2.18
//! p 456 (SBYCR), Ch 11.2.20 p 457 (LPSCR) and Ch 11.2.21 p 458 (DPSBYCR).
//!
//! The protection matters more than the bytes. ra8_lpm.c does NOT unlock PRCR
//! itself: its own header says "the driver assumes the caller has unlocked
//! PRC1 around protected writes" and exposes ra8_lpm_prcr_unlock/relock for
//! the caller to scope. A store that arrives with PRC1 clear is discarded by
//! silicon with no fault and no flag, exactly as PRCR's own header describes
//! for the CGC group. Modelling the registers without the gate would let
//! firmware that forgot the unlock configure a low-power state here and none
//! on the bench, which is the failure this model exists to catch.
//!
//! DELIBERATELY NOT MODELLED: entering any of these states. Nothing here
//! stops the core, gates a clock or powers a domain down; LPSCR records which
//! state a WFI would ask for, and the report says so.
//!
//! SSCR1 (0x4001_EA98, 8b, HUM Ch 11.2.19 p 456) holds SS2FR (bit 0, fast
//! return from Software Standby) and SS2LP (bits 3:2, its low-power setting).
//! ra8_lpm_init writes it and power_profiler reaches that path, so it is held
//! here behind the same PRC1 gate; the other bits read 0 whatever was written.
/// DPSIER/DPSIFR/DPSIEGR, the deep-standby cancel bytes: dps.zig.
pub const dps = @import("dps.zig");
const periph = @import("../registry.zig");
const prcr = @import("../prcr.zig");
pub const mode = @import("mode.zig");

/// The group these sit behind: PRC1, low-power modes and the VBATT file.
pub const guard: u16 = prcr.group.lpm;

/// Which register answers where. Three single-byte registers scattered across
/// the SYSC page, so each gets its own bus window rather than one span that
/// would swallow everything between 0x00C and 0xA90.
pub const Slot = struct {
    address: u32,
    name: []const u8,
};

pub const slots = [_]Slot{
    .{ .address = 0x4001_E00C, .name = "SBYCR" },
    .{ .address = 0x4001_EA00, .name = "DPSBYCR" },
    .{ .address = 0x4001_EA90, .name = "LPSCR" },
    .{ .address = 0x4001_EA98, .name = "SSCR1" },
};

pub const index = struct {
    pub const sbycr: usize = 0;
    pub const dpsbycr: usize = 1;
    pub const lpscr: usize = 2;
    pub const sscr1: usize = 3;
};

/// Which register an access names, if any. A wider access is answered by the
/// register at its base, the way a word store of a byte register is.
pub fn indexOf(address: u32) ?usize {
    for (&slots, 0..) |one, which| {
        if (one.address == address) return which;
    }
    return null;
}

pub const field = struct {
    /// SBYCR.OPE, bit 6. The rest of SBYCR is not software-writable.
    pub const ope: u8 = 0x40;
    /// DPSBYCR.IOKEEP, bit 6.
    pub const iokeep: u8 = 0x40;
    /// DPSBYCR.DCSSMODE, bits 3:2.
    pub const dcssmode: u8 = 0x0C;
    pub const dcssmode_shift: u3 = 2;
    /// DPSBYCR bit 4 reads as 1, so it is part of every readback.
    pub const dpsbycr_read_as_one: u8 = 0x10;
    /// LPSCR.LPMD, bits 3:0.
    pub const lpmd: u8 = 0x0F;
    /// SSCR1.SS2FR, bit 0: fast return from Software Standby.
    pub const ss2fr: u8 = 0x01;
    /// SSCR1.SS2LP, bits 3:2: the Software Standby low-power setting.
    pub const ss2lp: u8 = 0x0C;
    pub const ss2lp_shift: u3 = 2;
};

pub const reset = struct {
    /// OPE = 1, everything else 0 (HUM Ch 11.2.18 p 456).
    pub const sbycr: u8 = 0x40;
    /// Bit 4 reads as 1 plus DCSSMODE = 01b, 128 us soft-start.
    pub const dpsbycr: u8 = 0x14;
    /// LPMD = 0, System Active.
    pub const lpscr: u8 = 0x00;
    /// SS2FR = 0, SS2LP = 00b, default mode.
    pub const sscr1: u8 = 0x00;
};

/// The three retained bytes, plus what the run did to them.
pub const Unit = struct {
    protection: *const prcr.Prcr,
    sbycr: u8 = reset.sbycr,
    dpsbycr: u8 = reset.dpsbycr,
    lpscr: u8 = reset.lpscr,
    sscr1: u8 = reset.sscr1,
    /// Stores that landed.
    stores: u32 = 0,
    /// Stores dropped because PRCR.PRC1 was locked.
    dropped_locked: u32 = 0,
    /// Stores asking for DCSSMODE 0, which the HUM marks prohibited.
    prohibited_softstart: u32 = 0,
    /// Stores selecting an LPMD code the HUM does not define.
    undefined_modes: u32 = 0,
    /// Stores selecting a state deeper than Sleep.
    standby_selects: u32 = 0,

    pub fn init(protection: *const prcr.Prcr) Unit {
        return .{ .protection = protection };
    }

    /// A run that never touched these has nothing to narrate.
    pub fn quiet(self: *const Unit) bool {
        return self.stores == 0 and self.dropped_locked == 0;
    }

    /// The state a WFI would ask for, or null when firmware selected a code
    /// the HUM does not define.
    pub fn state(self: *const Unit) ?mode.Mode {
        return mode.modeOf(@truncate(self.lpscr & field.lpmd));
    }

    /// DCSSMODE as an encoding, prohibited included so the report can say so.
    pub fn softStart(self: *const Unit) mode.SoftStart {
        return mode.softStartOf(@truncate((self.dpsbycr & field.dcssmode) >> field.dcssmode_shift));
    }

    /// SBYCR.OPE: whether bus signal output is kept through standby.
    pub fn busOutputKept(self: *const Unit) bool {
        return self.sbycr & field.ope != 0;
    }

    /// SSCR1.SS2FR: whether a return from Software Standby takes the fast path.
    pub fn fastReturn(self: *const Unit) bool {
        return self.sscr1 & field.ss2fr != 0;
    }

    /// SSCR1.SS2LP as its two-bit code.
    pub fn standbyLowPower(self: *const Unit) u2 {
        return @truncate((self.sscr1 & field.ss2lp) >> field.ss2lp_shift);
    }

    /// DPSBYCR.IOKEEP: whether the I/O port state is kept through deep standby.
    pub fn ioKept(self: *const Unit) bool {
        return self.dpsbycr & field.iokeep != 0;
    }

    pub fn read(self: *Unit, address: u32, width: u3) u32 {
        _ = width;
        const which = indexOf(address) orelse return 0;
        return switch (which) {
            index.sbycr => self.sbycr,
            index.dpsbycr => self.dpsbycr,
            index.lpscr => self.lpscr,
            else => self.sscr1,
        };
    }

    pub fn write(self: *Unit, address: u32, width: u3, value: u32) void {
        _ = width;
        const which = indexOf(address) orelse return;
        // Protection first: a store nobody unlocked never reaches the byte.
        if (!self.protection.unlocked(guard)) {
            self.dropped_locked +%= 1;
            return;
        }
        const written: u8 = @truncate(value);
        switch (which) {
            index.sbycr => self.sbycr = written & field.ope,
            index.dpsbycr => self.storeDeepStandby(written),
            index.lpscr => self.storeState(written),
            else => self.sscr1 = written & (field.ss2fr | field.ss2lp),
        }
        self.stores +%= 1;
    }

    /// DPSBYCR keeps IOKEEP and DCSSMODE; bit 4 reads back as 1 whatever was
    /// written. DCSSMODE 0 is counted rather than refused: the HUM calls it
    /// prohibited without saying what the hardware does, and inventing a
    /// refusal would be inventing behaviour.
    fn storeDeepStandby(self: *Unit, written: u8) void {
        self.dpsbycr = (written & (field.iokeep | field.dcssmode)) | field.dpsbycr_read_as_one;
        if (self.softStart() == .prohibited) self.prohibited_softstart +%= 1;
    }

    /// LPSCR keeps LPMD. An undefined code is kept and counted for the same
    /// reason: the readback is what firmware wrote, and the report names it.
    fn storeState(self: *Unit, written: u8) void {
        self.lpscr = written & field.lpmd;
        if (self.state()) |selected| {
            if (selected.stopsPeripherals()) self.standby_selects +%= 1;
        } else {
            self.undefined_modes +%= 1;
        }
    }

    /// One bus entry per register.
    pub fn block(self: *Unit, which: usize) periph.Block {
        return .{
            .name = slots[which].name,
            .base = slots[which].address,
            .size = 1,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Unit = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Unit = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
