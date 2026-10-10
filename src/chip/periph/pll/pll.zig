//! The PLL configuration registers, PLL1's and PLL2's, plus MOSCWTCR, behind
//! PRCR.PRC0, with the divider code the hardware silently rejects.
//!
//! PLL1's three were the next most-written unmodelled addresses in the EIL
//! corpus after the low-power bytes: 26 of the 36 images write all three,
//! always the same values. They come from ra8_cgc.c's clock bring-up:
//! internal_start_main_osc writes MOSCWTCR = 9 before releasing the main
//! oscillator, and internal_program_and_start_pll1 writes PLLCCR = 0xFA02
//! and PLLCCR2 = 0x451, the EK-RA8D2 quickstart numbers (XTAL 24 MHz, /3 in,
//! x250.00, P=/2, Q=/6, R=/5), between stopping and restarting PLL1.
//!
//! PLL2 IS THE USB CLOCK'S PLL and was entirely unmodelled until this file
//! grew to hold it: both its registers fell to the SYSC catch-all, which
//! stores whatever it is handed and reads it back, so every rule below was
//! missing for the one PLL whose driver path is the most careful about them.
//! ra8_cgc_usb.c's internal_pll2_program_protected stops PLL2, waits for
//! OSCSF.PLL2SF to clear, writes PLL2CCR then PLL2CCR2, and restarts it, all
//! inside RA8_PROTECTED_WRITE(unlock_cgc), and ra8_cgc_pll2_enable computes
//! Q and R as /6 purely so no field carries the prohibited code, saying so in
//! its own comment: "Code 0 is prohibited per HUM Ch 9.2.10/9.2.12 (drops the
//! whole 16-bit write)."
//!
//!   PLLCCR2  (0x4001_E04C, 16b)  PLODIVP[3:0] PLODIVQ[7:4] PLODIVR[11:8]
//!   PLL2CCR2 (0x4001_E04E, 16b)  the same three fields
//!   MOSCWTCR (0x4001_E0A2,  8b)  main oscillator wait cycles
//!   PLLCCR   (0x4001_E0AC, 32b)  PLIDIV[1:0] PLSRCSEL[4] PLLMULNF[7:6]
//!                                PLLMUL[16:8]
//!   PLL2CCR  (0x4001_E0C8, 32b)  the same four fields
//!
//! Offsets and field layouts are from libs/ra8_hal/inc/ra8_system_regs.h and
//! ra8_cgc_regs.h on zig/dev, which cite HUM Ch 9.2.6 p 331 (PLLCCR),
//! Ch 9.2.7 p 332 (PLLCCR2), Ch 9.2.10 p 335 (PLL2CCR), Ch 9.2.12 p 335
//! (PLL2CCR2) and Ch 9.2.27 p 349 (MOSCWTCR) alongside the FSP CMSIS header
//! and bsp_clocks.c. PLL2CR, the stop control, is not here: oscsf.zig already
//! owns it and the run state it drives.
//!
//! Three rules make these worth modelling rather than storing, and all three
//! apply to both PLLs.
//!
//! PRC0, the same gate sysclk.zig takes: these are CGC registers, and both
//! drivers only reach them inside RA8_PROTECTED_WRITE(unlock_cgc). A store
//! arriving with PRC0 clear is discarded by silicon with no fault and no flag.
//!
//! THE PROHIBITED DIVIDER, which belongs to the CCR2 of either PLL: the bit
//! pattern 0000 in any of PLODIVP, PLODIVQ or PLODIVR is "Setting prohibited"
//! per HUM Ch 9.2.7 and Ch 9.2.10/9.2.12, and ra8_cgc_regs.h records what the
//! hardware does with it in so many words: the entire 16-bit register write is
//! dropped and the register keeps its previous value. That is why
//! k_ra8_plodiv_div1 is absent from the firmware enum. A model that stored the
//! word anyway would let firmware configure a PLL output ratio here that
//! silicon never accepted, and the run would report a clock tree the bench
//! does not have. The rule lives in `config.zig` now that two PLLs need
//! it.
//!
//! AND THE STOP BARRIER, which this file previously wrote off as a driver
//! contract and which the tree says outright is the hardware's. ra8_cgc.c's
//! own file header, step 3: "Stop PLL1 (PLLCR = 1), then poll OSCSF.PLLSF = 0.
//! Without this barrier, PLLCCR / PLLCCR2 writes are silently dropped and read
//! back as zero." That is not a precondition the driver keeps out of tidiness,
//! it is what silicon does, and internal_cgc_init_protected orders
//! internal_stop_pll1 before internal_program_and_start_pll1 for exactly that
//! reason. PLL2 has the same barrier on its own flag, cited at HUM Ch 9.2.11
//! p 336 in internal_pll2_program_protected, and ra8_cgc_pll2_enable leans on
//! it the other way round: finding PLL2SF already set, it returns early
//! WITHOUT reprogramming, because a live PLL2 would take nothing and the USB
//! clock hanging off PLL2P would lose its source. So a configuration store
//! arriving while that PLL's OSCSF flag is set is dropped and counted, and a
//! later read gives back what was there before, which before any successful
//! store is zero, the way the driver's note says.
//!
//! EACH PLL CARRIES ITS OWN BARRIER FLAG, as data on the slot rather than a
//! special case in the store path: PLL1's registers watch OSCSF.PLL1SF, PLL2's
//! watch PLL2SF, and MOSCWTCR watches nothing.
//!
//! MOSCWTCR IS OUTSIDE THE BARRIER and deliberately so: it is the main
//! oscillator's wait count, written in step 1 by internal_start_main_osc,
//! before PLL1 is stopped at all, and nothing in the tree ties it to either
//! PLL's run state.
//!
//! DELIBERATELY NOT MODELLED. The reset values: nothing in the tree records
//! them, so the registers start at zero here and the report only speaks once
//! firmware has written. No frequency is derived: the multipliers and the
//! ratios are reported as written, because turning them into megahertz would
//! need the XTAL rate, which this emulator does not model. Nothing derives
//! USBCLK from PLL2P either, for the same reason. Nor does anything here check
//! the core voltage range VSCR selected: step 2 is a brown-out hazard rather
//! than a rule the clock registers enforce, so it belongs to whatever models
//! the consequence, not to this file.
const periph = @import("../registry.zig");
const prcr = @import("../prcr.zig");
const oscsf = @import("../oscsf.zig");
const div = @import("div.zig");
const config = @import("config.zig");
const lanes = @import("../lanes.zig");

/// The group these sit behind: PRC0, the clock generation circuit.
pub const guard: u16 = prcr.group.cgc;

/// Which PLL a register belongs to, and what part of its pair it is.
pub const Role = enum { ccr, ccr2, wait };

pub const Slot = struct {
    address: u32,
    span: u32,
    name: []const u8,
    role: Role,
    /// Which PLL's pair this is, or null for MOSCWTCR.
    pll: ?Which = null,
};

/// The two PLLs this file holds a configuration pair for.
pub const Which = enum { pll1, pll2 };

/// Five registers scattered across the SYSC page, so each gets its own bus
/// window rather than one span that would swallow everything between them.
pub const slots = [_]Slot{
    .{ .address = 0x4001_E04C, .span = 2, .name = "PLLCCR2", .role = .ccr2, .pll = .pll1 },
    .{ .address = 0x4001_E04E, .span = 2, .name = "PLL2CCR2", .role = .ccr2, .pll = .pll2 },
    .{ .address = 0x4001_E0A2, .span = 1, .name = "MOSCWTCR", .role = .wait },
    .{ .address = 0x4001_E0AC, .span = 4, .name = "PLLCCR", .role = .ccr, .pll = .pll1 },
    .{ .address = 0x4001_E0C8, .span = 4, .name = "PLL2CCR", .role = .ccr, .pll = .pll2 },
};

pub const index = struct {
    pub const pllccr2: usize = 0;
    pub const pll2ccr2: usize = 1;
    pub const moscwtcr: usize = 2;
    pub const pllccr: usize = 3;
    pub const pll2ccr: usize = 4;
};

/// The OSCSF flag whose standing bit shuts a PLL's configuration barrier.
pub fn barrierFlag(which: Which) u8 {
    return switch (which) {
        .pll1 => oscsf.flag.pll1sf,
        .pll2 => oscsf.flag.pll2sf,
    };
}

/// Which register an access names. A wider or narrower access is answered by
/// the register whose window it lands in, the way the rest of SYSC is.
pub fn indexOf(address: u32) ?usize {
    for (&slots, 0..) |one, which| {
        if (address >= one.address and address < one.address + one.span) return which;
    }
    return null;
}

/// The retained words, plus what the run did to them.
pub const Unit = struct {
    protection: *const prcr.Prcr,
    /// The board's live oscillators, so each PLL's run state is read rather
    /// than tracked twice. Not a copy: the stop bits move under this pointer.
    oscillators: *const oscsf.Oscillators,
    pll1: config.Config = .{},
    pll2: config.Config = .{},
    moscwtcr: u8 = 0,
    /// Stores dropped because PRCR.PRC0 was locked, for either PLL and for
    /// MOSCWTCR alike: the gate stands in front of the whole file.
    dropped_locked: u32 = 0,
    /// MOSCWTCR stores that landed.
    wait_stores: u32 = 0,

    pub fn init(protection: *const prcr.Prcr, oscillators: *const oscsf.Oscillators) Unit {
        return .{ .protection = protection, .oscillators = oscillators };
    }

    pub fn quiet(self: *const Unit) bool {
        return self.dropped_locked == 0 and self.wait_stores == 0 and
            self.pll1.quiet() and self.pll2.quiet();
    }

    /// One PLL's configuration pair.
    pub fn pll(self: *Unit, which: Which) *config.Config {
        return switch (which) {
            .pll1 => &self.pll1,
            .pll2 => &self.pll2,
        };
    }

    /// Whether that PLL is turning right now, which is what shuts its
    /// barrier.
    fn running(self: *const Unit, which: Which) bool {
        return self.oscillators.running(barrierFlag(which));
    }

    pub fn read(self: *Unit, address: u32, width: u3) u32 {
        const at = indexOf(address) orelse return 0;
        const slot = slots[at];
        const word: u32 = switch (slot.role) {
            .wait => self.moscwtcr,
            .ccr => self.pll(slot.pll.?).ccr,
            .ccr2 => self.pll(slot.pll.?).ccr2,
        };
        return lanes.part(word, address - slot.address, width);
    }

    pub fn write(self: *Unit, address: u32, width: u3, value: u32) void {
        const at = indexOf(address) orelse return;
        const slot = slots[at];
        // Protection first: a store nobody unlocked never reaches the word.
        if (!self.protection.unlocked(guard)) {
            self.dropped_locked +%= 1;
            return;
        }
        const lane = address - slot.address;
        if (slot.role == .wait) {
            self.moscwtcr = @truncate(lanes.merge(self.moscwtcr, lane, width, value));
            self.wait_stores +%= 1;
            return;
        }
        // Step 3's barrier: a PLL's configuration pair takes nothing while it
        // turns. MOSCWTCR is not part of any pair; see the header.
        const which = slot.pll.?;
        const one = self.pll(which);
        if (self.running(which)) {
            one.refuseRunning();
            return;
        }
        switch (slot.role) {
            .ccr => one.storeCcr(lane, width, value),
            .ccr2 => one.storeCcr2(lane, width, value),
            .wait => unreachable,
        }
    }

    /// One bus entry per register.
    pub fn block(self: *Unit, which: usize) periph.Block {
        return .{
            .name = slots[which].name,
            .base = slots[which].address,
            .size = slots[which].span,
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
