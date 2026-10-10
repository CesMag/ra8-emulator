//! GLCDC TCON: the panel's own timing, and which pin carries which sync.
//!
//! The mixer composites onto a panel, and until now this model had to guess
//! how big that panel was: it took the furthest a programmed layer reached.
//! The panel is not the layer. TCON is where the driver writes the timing it
//! read out of the board's panel table (ra8_glcdc.c internal_program_tcon),
//! so the active area, the sync widths and the back porches are all here in
//! registers, and a layer smaller than the panel leaves background around it
//! rather than shrinking the glass.
//!
//! The four STxx2 registers are pin configuration, not timing: each one
//! drives one LCD_TCONn pin, picking the internal signal that reaches it
//! (SEL [2:0]) and whether it is inverted on the way out (INV, bit 4). The
//! in-tree driver routes VSYNC to TCON0 active-low, HSYNC to TCON1 active-low
//! via STVB, and DE to TCON2 active-high; a panel wired for the other
//! polarity shows a picture on the bench and nothing on the glass, which is
//! the kind of thing worth having in the report.
//!
//! dev's board_periph_glcdc.c snoops eleven offsets and none of them are in
//! this block, so every one of these writes went into a shadow word nobody
//! read.

/// Register byte offsets inside the GLCDC window (ra8_glcdc_regs.h).
pub const off = struct {
    pub const base: u32 = 0x1400;
    pub const span: u32 = 0x2C;
    /// TCON.TIM: reference timing offset for the whole block.
    pub const tim: u32 = 0x1404;
    pub const stva1: u32 = 0x1408;
    pub const stva2: u32 = 0x140C;
    pub const stvb1: u32 = 0x1410;
    pub const stvb2: u32 = 0x1414;
    pub const stha1: u32 = 0x1418;
    pub const stha2: u32 = 0x141C;
    pub const sthb1: u32 = 0x1420;
    pub const sthb2: u32 = 0x1424;
    pub const de: u32 = 0x1428;
};

/// Field positions the driver writes through (HUM Ch 63 p 3805).
pub const field = struct {
    /// STVA1/STHA1 carry a pulse width in lines or pixel clocks.
    pub const pulse_mask: u32 = 0x7FF;
    /// STVB1/STHB1 pack the active-area start high and its size low.
    pub const start_shift: u5 = 16;
    pub const start_mask: u32 = 0x7FF;
    pub const active_mask: u32 = 0x7FF;
    /// STxx2.SEL [2:0]: which internal signal drives this pin.
    pub const sel_mask: u32 = 0x7;
    /// STxx2.INV, bit 4: the pin is inverted on the way out.
    pub const invert: u32 = 0x10;
};

/// The internal timing signal a pin is driven from. Non-exhaustive: the
/// field is three bits wide and the driver names four of the eight.
pub const Signal = enum(u3) {
    stva = 0,
    stvb = 1,
    stha = 2,
    sthb = 3,
    de = 7,
    _,

    /// What to call this signal in a report line.
    pub fn name(self: Signal) []const u8 {
        return switch (self) {
            .stva => "STVA",
            .stvb => "STVB",
            .stha => "STHA",
            .sthb => "STHB",
            .de => "DE",
            _ => "reserved",
        };
    }
};

/// One LCD_TCONn output pin, as its STxx2 register left it.
pub const Pin = struct {
    signal: Signal = .stva,
    inverted: bool = false,
    programmed: bool = false,

    fn latch(self: *Pin, value: u32) void {
        self.signal = @fromBackingInt(@intCast(value & field.sel_mask));
        self.inverted = value & field.invert != 0;
        self.programmed = true;
    }
};

/// How many pins the block drives: LCD_TCON0..3, one per STxx2 register.
pub const pins: usize = 4;

/// The panel timing the four timing registers describe. Sizes are in lines
/// vertically and pixel clocks horizontally, the units the driver wrote.
pub const Timing = struct {
    h_sync: u32,
    h_back: u32,
    h_active: u32,
    v_sync: u32,
    v_back: u32,
    v_active: u32,

    /// Where the first active pixel of a line sits, counted from the start
    /// of the sync pulse. This is the number STHB1 actually carries; the
    /// back porch is what is left once the pulse is taken off it.
    pub fn hStart(self: Timing) u32 {
        return self.h_sync + self.h_back;
    }

    pub fn vStart(self: Timing) u32 {
        return self.v_sync + self.v_back;
    }
};

/// The timing controller: the decoded timing, the pin routing, and enough
/// counting to tell a block that was programmed from one that was not.
pub const Tcon = struct {
    /// STVA1 and STHA1: the sync pulse widths.
    v_sync: u32 = 0,
    h_sync: u32 = 0,
    /// STVB1 and STHB1: where the active area starts and how big it is.
    v_start: u32 = 0,
    v_active: u32 = 0,
    h_start: u32 = 0,
    h_active: u32 = 0,
    /// TCON.TIM and TCON.DE, kept so a non-default value is visible.
    tim: u32 = 0,
    de: u32 = 0,
    /// LCD_TCON0..3, in that order.
    pin: [pins]Pin = @splat(.{}),
    /// Writes this block took.
    writes: u32 = 0,
    /// Whether both active-area registers have been written, which is what
    /// makes the timing a panel rather than a half-filled struct.
    sized: bool = false,

    /// Take a write in the GLCDC window. True when it belonged here, so the
    /// caller knows the block claimed it; the word is still shadowed by the
    /// caller for read-back either way.
    pub fn latch(self: *Tcon, offset: u32, value: u32) bool {
        if (!owns(offset)) return false;
        self.writes +%= 1;
        switch (offset) {
            off.tim => self.tim = value,
            off.de => self.de = value,
            off.stva1 => self.v_sync = value & field.pulse_mask,
            off.stha1 => self.h_sync = value & field.pulse_mask,
            off.stvb1 => self.area(value, true),
            off.sthb1 => self.area(value, false),
            off.stva2 => self.pin[0].latch(value),
            off.stvb2 => self.pin[1].latch(value),
            off.stha2 => self.pin[2].latch(value),
            off.sthb2 => self.pin[3].latch(value),
            else => {},
        }
        return true;
    }

    fn area(self: *Tcon, value: u32, vertical: bool) void {
        const start = value >> field.start_shift & field.start_mask;
        const size = value & field.active_mask;
        if (vertical) {
            self.v_start = start;
            self.v_active = size;
        } else {
            self.h_start = start;
            self.h_active = size;
        }
        self.sized = self.v_active != 0 and self.h_active != 0;
    }

    /// The timing, or null when the active area was never programmed. A
    /// back porch shorter than its own sync pulse is not a timing anyone
    /// wrote on purpose, so it comes back as zero rather than wrapping.
    pub fn timing(self: *const Tcon) ?Timing {
        if (!self.sized) return null;
        return .{
            .h_sync = self.h_sync,
            .h_back = subtract(self.h_start, self.h_sync),
            .h_active = self.h_active,
            .v_sync = self.v_sync,
            .v_back = subtract(self.v_start, self.v_sync),
            .v_active = self.v_active,
        };
    }

    /// Which pin carries a signal, or null when none is routed to it. The
    /// driver's own question: is VSYNC actually leaving the part?
    pub fn pinFor(self: *const Tcon, signal: Signal) ?usize {
        for (self.pin, 0..) |one, index| {
            if (one.programmed and one.signal == signal) return index;
        }
        return null;
    }

    /// Whether a rectangle fits inside the active area. A layer that does
    /// not is clipped by the panel on silicon, however well it scans here.
    pub fn contains(self: *const Tcon, width: u32, height: u32) bool {
        const found = self.timing() orelse return true;
        return width <= found.h_active and height <= found.v_active;
    }

    /// A block nobody wrote to has nothing to narrate.
    pub fn quiet(self: *const Tcon) bool {
        return self.writes == 0;
    }
};

/// Whether an offset inside the GLCDC window belongs to this block.
pub fn owns(offset: u32) bool {
    return offset >= off.base and offset < off.base + off.span;
}

fn subtract(from: u32, amount: u32) u32 {
    return if (from > amount) from - amount else 0;
}
