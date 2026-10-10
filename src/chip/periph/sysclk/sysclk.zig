//! The system clock tree: which source drives it, and the dividers under it.
//!
//! (SYSC base 0x4001_E000, HUM Ch 9.2.5 "SCKSCR", 9.2.6 "SCKDIVCR",
//! 9.2.7 "SCKDIVCR2".)
//!
//!   SCKDIVCR  (+0x020, 32b) FCLK, ICLK, PCLKE, BCLK, PCLKA..D dividers
//!   SCKDIVCR2 (+0x024, 16b) CPUCLK0, CPUCLK1, NPUCLK, MRICLK dividers
//!   SCKSCR    (+0x026,  8b) CKSEL[2:0], the source the whole tree runs on
//!
//! THE GAP THIS CLOSES. None of the three was modelled, so all of them fell to
//! the bus catch-all, which stores what it is handed and reads it back. Two
//! consequences. Every store landed whether or not PRC0 was open, and the run
//! could say nothing at all about the clock tree: 26 of the 36 corpus images
//! programme these registers during bring-up and the report never mentioned
//! them, so a run had no way to show which source the firmware ended up on.
//!
//! PRCR.PRC0 GATES EVERY STORE HERE, the same rule `oscsf.zig` next door
//! already carries for the stop bits: these are clock-generation registers, and
//! ra8_lpm.h lines 572-573 record that "a write issued while PRC0 is locked is
//! discarded silently by the hardware" (HUM Ch 13.1 Table 13.1). No fault, no
//! status bit, the register simply keeps its old value. A store arriving with
//! PRC0 shut is dropped and counted, because counting it is the only way a run
//! can say it happened.
//!
//! The firmware is careful here and that is exactly why the gate matters.
//! internal_cgc_init_protected (ra8_cgc.c:688) runs the whole bring-up inside
//! RA8_PROTECTED_WRITE(k_ra8_prcr_unlock_cgc), and its last two steps are
//! internal_program_dividers (both divider words) then SCKSCR = PLL1 at line
//! 722; ra8_cgc_use_hoco wraps its lone SCKSCR store at line 773; and
//! switch_pll1_target wraps each of its three at 823, 832 and 846. Every one of
//! those windows is a place a caller can get the protection wrong and lose the
//! write on silicon while a model that gates nothing carries on.
//!
//! SELECTING A SOURCE THAT IS NOT RUNNING IS COUNTED, NOT REFUSED. The driver
//! waits on the matching OSCSF flag before it dares select a source
//! (priv_ra8_cgc_wait_oscsf_set, called at every bring-up step), so a select
//! that skips the wait is a real firmware bug. But nothing in this tree records
//! the hardware REFUSING such a select, so this model does not invent a
//! refusal: the select lands, and the run says it happened. Only the four
//! sources with an OSCSF flag can be checked at all, so MOCO, LOCO and the
//! sub-clock are selected without comment.
//!
//! THE RESET VALUES OF THE TWO DIVIDER WORDS ARE NOT RECORDED in the firmware
//! tree, so nothing here claims one: both answer zero until firmware programmes
//! them, and the report stays silent about a tree that was never written. That
//! zero is the model's starting point, not a claim about silicon. SCKSCR is
//! different and is cited: ra8_cgc.h lines 241 and 380 both record that the
//! reset value "reads as 0 (... = HOCO ~20 MHz)", so CKSEL starts at HOCO.
//!
//! NO FREQUENCY IS DERIVED. The dividers are decoded to ratios for the report
//! (`div.zig`) and nothing more: this model has no oscillator
//! frequencies behind it, and the modelled time base is charged per chunk
//! rather than per cycle (`clocks.zig`), so a rate computed here would be
//! decoration. Wiring real rates into the time base is its own slice.
const periph = @import("../registry.zig");
const prcr = @import("../prcr.zig");
const oscsf = @import("../oscsf.zig");
pub const div = @import("div.zig");
/// Each core's clock in Hz, from this tree (RA8EMU-515).
pub const rate = @import("rate.zig");
const hazard = @import("../voltage_hazard.zig");

/// Window geometry: SCKDIVCR (+0x020) through SCKSCR (+0x026) inclusive.
pub const win_base: u32 = 0x4001_E020;
pub const win_span: u32 = 0x7;

/// Register offsets from `win_base`.
pub const regs = struct {
    pub const sckdivcr: u32 = 0x00;
    pub const sckdivcr2: u32 = 0x04;
    pub const sckscr: u32 = 0x06;
};

/// SCKSCR.CKSEL values (ra8_cksel_t).
pub const Source = enum(u3) {
    hoco = 0,
    moco = 1,
    loco = 2,
    main = 3,
    subck = 4,
    pll1 = 5,
    pll2 = 6,
    /// 7 is not in ra8_cksel_t; the encoding is not recorded here.
    reserved = 7,

    pub fn name(self: Source) []const u8 {
        return switch (self) {
            .hoco => "HOCO",
            .moco => "MOCO",
            .loco => "LOCO",
            .main => "MAIN",
            .subck => "SUBCLK",
            .pll1 => "PLL1",
            .pll2 => "PLL2",
            .reserved => "reserved",
        };
    }

    /// The OSCSF flag that says this source has stabilised, for the four that
    /// have one. MOCO, LOCO and the sub-clock do not appear in OSCSF, so they
    /// cannot be checked and answer null.
    pub fn stability(self: Source) ?u8 {
        return switch (self) {
            .hoco => oscsf.flag.hocosf,
            .main => oscsf.flag.moscsf,
            .pll1 => oscsf.flag.pll1sf,
            .pll2 => oscsf.flag.pll2sf,
            .moco, .loco, .subck, .reserved => null,
        };
    }

    /// Whether running the tree on this source lifts CPUCLK0 far enough for
    /// the core voltage range to matter. ra8_cgc.c's step 2 exists for the
    /// PLL bring-up and for nothing else, so only a PLL answers true; see
    /// voltage_hazard.zig.
    pub fn liftsCore(self: Source) bool {
        return switch (self) {
            .pll1, .pll2 => true,
            .hoco, .moco, .loco, .main, .subck, .reserved => false,
        };
    }
};

/// CKSEL[2:0]; the bits above it are reserved and read zero.
pub const cksel_mask: u8 = 0x07;

/// The PRCR group that has to be open for a store to land: PRC0, the clock
/// generation circuit (k_ra8_prcr_grp0_cgc).
pub const guard: u16 = prcr.group.cgc;

/// The tree, and the counters behind the end-of-run lines.
pub const Tree = struct {
    /// The board's live protection model, not a copy of it.
    protection: *const prcr.Prcr,
    /// The board's live oscillators, so a select can be checked against the
    /// stabilisation flags the driver is supposed to have waited on.
    oscillators: *const oscsf.Oscillators,
    /// The brown-out watch, told about every select that lifts the core. Not
    /// a copy: it reads the voltage range live.
    brownout: *hazard.Watch,
    divcr: u32 = 0,
    divcr2: u16 = 0,
    /// CKSEL. Resets to HOCO; see the header.
    cksel: u8 = @backingInt(Source.hoco),
    /// Divider words the firmware programmed.
    programmed: u32 = 0,
    /// Source selects that landed.
    selects: u32 = 0,
    /// Stores dropped because PRC0 was shut.
    dropped_locked: u32 = 0,
    /// Selects of a source whose OSCSF flag was not up.
    unstable_selects: u32 = 0,
    /// Selects of CKSEL = 7, which ra8_cksel_t does not define.
    reserved_selects: u32 = 0,

    pub fn init(
        protection: *const prcr.Prcr,
        oscillators: *const oscsf.Oscillators,
        brownout: *hazard.Watch,
    ) Tree {
        return .{
            .protection = protection,
            .oscillators = oscillators,
            .brownout = brownout,
        };
    }

    /// Untouched units stay out of the end-of-run report.
    pub fn quiet(self: *const Tree) bool {
        return self.programmed == 0 and self.selects == 0 and
            self.dropped_locked == 0 and self.unstable_selects == 0 and
            self.reserved_selects == 0;
    }

    /// The source the tree is running on right now.
    pub fn source(self: *const Tree) Source {
        return @fromBackingInt(@intCast(self.cksel & cksel_mask));
    }

    /// What one domain of SCKDIVCR divides by, or null for a code the firmware
    /// tree does not define.
    pub fn ratioOf(self: *const Tree, domain: div.Domain) ?u32 {
        return div.ratio(div.codeAt(self.divcr, domain.at));
    }

    /// The same for SCKDIVCR2.
    pub fn ratioOf2(self: *const Tree, domain: div.Domain) ?u32 {
        return div.ratio(div.codeAt(self.divcr2, domain.at));
    }

    fn byteAt(self: *const Tree, offset: u32) u8 {
        return switch (offset) {
            regs.sckdivcr...regs.sckdivcr + 3 => @truncate(self.divcr >> @intCast((offset - regs.sckdivcr) * 8)),
            regs.sckdivcr2, regs.sckdivcr2 + 1 => @truncate(self.divcr2 >> @intCast((offset - regs.sckdivcr2) * 8)),
            regs.sckscr => self.cksel & cksel_mask,
            else => 0,
        };
    }

    pub fn read(self: *Tree, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        var out: u32 = 0;
        var lane: u32 = 0;
        while (lane < width) : (lane += 1) {
            out |= @as(u32, self.byteAt(offset + lane)) << @intCast(lane * 8);
        }
        return out;
    }

    pub fn write(self: *Tree, address: u32, width: u3, value: u32) void {
        // PRC0 shut means the hardware discards the store with no fault and no
        // status bit. Counting it is the only way the run can say so.
        if (!self.protection.unlocked(guard)) {
            self.dropped_locked +%= 1;
            return;
        }
        const offset = address -% win_base;
        var lane: u32 = 0;
        while (lane < width) : (lane += 1) {
            const at = offset + lane;
            if (at >= win_span) continue;
            self.storeByte(at, @truncate(value >> @intCast(lane * 8)));
        }
    }

    fn storeByte(self: *Tree, offset: u32, byte: u8) void {
        switch (offset) {
            regs.sckdivcr...regs.sckdivcr + 3 => {
                const shift: u5 = @intCast((offset - regs.sckdivcr) * 8);
                self.divcr = (self.divcr & ~(@as(u32, 0xFF) << shift)) | (@as(u32, byte) << shift);
                self.programmed +%= 1;
            },
            regs.sckdivcr2, regs.sckdivcr2 + 1 => {
                const shift: u4 = @intCast((offset - regs.sckdivcr2) * 8);
                self.divcr2 = (self.divcr2 & ~(@as(u16, 0xFF) << shift)) | (@as(u16, byte) << shift);
                self.programmed +%= 1;
            },
            regs.sckscr => self.select(byte),
            else => {},
        }
    }

    /// Take a CKSEL store, and say what the run should notice about it.
    fn select(self: *Tree, byte: u8) void {
        self.cksel = byte & cksel_mask;
        self.selects +%= 1;
        const picked = self.source();
        // Step 2's hazard, watched not enforced: the select lands whatever the
        // core voltage range is, and voltage_hazard.zig says why.
        self.brownout.selecting(picked.liftsCore());
        if (picked == .reserved) {
            self.reserved_selects +%= 1;
            return;
        }
        if (picked.stability()) |raises| {
            if (!self.oscillators.running(raises)) self.unstable_selects +%= 1;
        }
    }

    pub fn block(self: *Tree) periph.Block {
        return .{
            .name = "SYSC-SCKSCR",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Tree = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Tree = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
