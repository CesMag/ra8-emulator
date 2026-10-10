//! GLCDC SYSCNT: the panel clock, the state detections, and the status a
//! driver polls.
//!
//! Everything upstream of here decides what a pixel looks like. This block
//! decides whether a frame happens at all, and what the driver is told about
//! it afterwards. SYSCNT.PANEL_CLK gates the pixel clock: the in-tree driver
//! programs CLKSEL = LCDCLK, CLKEN and a divider in `ra8_glcdc_init` before
//! it touches a single timing register (ra8_glcdc.c, the PANEL_CLK write),
//! and a controller whose clock never started scans nothing however well its
//! layers are programmed.
//!
//! The other four registers are one status word seen from four sides:
//! DTCTEN arms a detection, INTEN lets an armed detection reach the
//! interrupt controller, STMON reports what has been detected, and STCLR
//! takes it back down. `ra8_glcdc_start` writes DTCTEN = 1 as its step 3,
//! naming the bit VPOSDTC, the line-detect source a display driver waits a
//! frame on.
//!
//! dev's board_periph_glcdc.c snoops eleven offsets and none of them are in
//! this block, so on that tree STMON read back whatever word had last been
//! written to it, which is zero: firmware that waits for a frame to land
//! waits forever, and firmware that clears a status it never had is told it
//! worked. The panel clock is not read there either, so a framebuffer was
//! hashed and reported as a picture with the clock still gated off.

/// Register byte offsets inside the GLCDC window (ra8_glcdc_regs.h, the
/// SYSCNT block at 0x1440).
pub const off = struct {
    pub const base: u32 = 0x1440;
    pub const span: u32 = 0x14;
    /// DTCTEN: which states are detected at all.
    pub const dtcten: u32 = 0x1440;
    /// INTEN: which detected states reach the interrupt controller.
    pub const inten: u32 = 0x1444;
    /// STCLR: write one to take a detected state back down.
    pub const stclr: u32 = 0x1448;
    /// STMON: what has been detected and not yet cleared.
    pub const stmon: u32 = 0x144C;
    /// PANEL_CLK: the pixel clock source, gate and divider.
    pub const panel_clk: u32 = 0x1450;
};

/// The four status registers share one bit order, so a driver arms, enables,
/// reads and clears the same state through the same mask.
pub const state = struct {
    /// VPOS: the scan reached the detection line. This is the bit
    /// `ra8_glcdc_start` arms as its step 3.
    pub const vpos: u32 = 1 << 0;
    /// GR1UF / GR2UF: that layer's fetch did not keep up with the scan.
    pub const gr1_underflow: u32 = 1 << 1;
    pub const gr2_underflow: u32 = 1 << 2;
    /// Every state this block models.
    pub const all: u32 = vpos | gr1_underflow | gr2_underflow;

    /// The underflow bit belonging to graphics layer 1 or 2.
    pub fn underflowOf(layer: u8) u32 {
        return if (layer == 1) gr1_underflow else gr2_underflow;
    }
};

/// PANEL_CLK fields, as the driver writes them (ra8_glcdc.c: CLKSEL at bit
/// 8, CLKEN at bit 6, the divider in the low bits).
pub const clock = struct {
    pub const source_shift: u5 = 8;
    pub const source_mask: u32 = 0x3;
    pub const enable: u32 = 1 << 6;
    pub const divider_mask: u32 = 0x3F;
};

/// Where the pixel clock is taken from. Non-exhaustive: the field is two
/// bits wide and the driver names one of the four.
pub const Source = enum(u2) {
    internal = 0,
    lcdclk = 1,
    _,

    pub fn name(self: Source) []const u8 {
        return switch (self) {
            .internal => "internal",
            .lcdclk => "LCDCLK",
            _ => "reserved",
        };
    }
};

/// The system control block: the clock gate, the status word, and enough
/// counting to tell a panel that never ran from one that ran unwatched.
pub const Syscnt = struct {
    /// DTCTEN: armed detections.
    detect: u32 = 0,
    /// INTEN: which armed detections would reach the interrupt controller.
    interrupts: u32 = 0,
    /// STMON: detected and not yet cleared.
    status: u32 = 0,
    /// PANEL_CLK, as written.
    panel_clk: u32 = 0,
    /// Writes this block took.
    writes: u32 = 0,
    /// Frames the panel scanned out.
    frames: u32 = 0,
    /// Frames refused because the pixel clock was never started.
    unclocked: u32 = 0,
    /// Frames that landed with VPOS detection disarmed, so nothing was
    /// reported to firmware waiting on it.
    undetected: u32 = 0,
    /// Times a detected state was raised into the status word.
    detections: u32 = 0,
    /// Detections that would have pended an interrupt, INTEN being set.
    interrupts_due: u32 = 0,
    /// Layer fetches that could not deliver, counted whether armed or not.
    underflows: u32 = 0,
    /// Bits written to STCLR that were not up in the first place. Firmware
    /// clearing a status it never had is firmware that believes it saw one.
    stale_clears: u32 = 0,
    /// Writes to STMON, which is read-only on silicon.
    status_writes: u32 = 0,

    /// A run that never touched the block has nothing to narrate.
    pub fn quiet(self: *const Syscnt) bool {
        return self.writes == 0 and self.frames == 0 and self.unclocked == 0;
    }

    /// Whether this offset belongs to the block.
    pub fn owns(offset: u32) bool {
        return offset >= off.base and offset < off.base + off.span;
    }

    /// Take a write. Returns true when the block consumed it; the caller
    /// still keeps the word in its shadow, which is what a read-back of
    /// DTCTEN or PANEL_CLK is answered from on silicon.
    pub fn latch(self: *Syscnt, offset: u32, value: u32) bool {
        if (!owns(offset)) return false;
        self.writes +%= 1;
        switch (offset) {
            off.dtcten => self.detect = value & state.all,
            off.inten => self.interrupts = value & state.all,
            off.stclr => self.clear(value),
            // STMON is read-only. dev lets the write land and then reads it
            // back as status, so a driver that writes there is told its own
            // word.
            off.stmon => self.status_writes +%= 1,
            off.panel_clk => self.panel_clk = value,
            else => return false,
        }
        return true;
    }

    /// Answer a read from the block's own state rather than the register
    /// shadow. STCLR is write-one-to-clear and holds nothing, so it reads
    /// back zero.
    pub fn read(self: *const Syscnt, offset: u32) ?u32 {
        return switch (offset) {
            off.dtcten => self.detect,
            off.inten => self.interrupts,
            off.stclr => 0,
            off.stmon => self.status,
            off.panel_clk => self.panel_clk,
            else => null,
        };
    }

    /// Write one to clear. A bit written against a state that is not up is
    /// counted: it is the shape of a driver that thinks it handled a frame.
    fn clear(self: *Syscnt, value: u32) void {
        const wanted = value & state.all;
        const stale = wanted & ~self.status;
        if (stale != 0) self.stale_clears +%= @popCount(stale);
        self.status &= ~wanted;
    }

    /// Whether the pixel clock is running. Nothing reaches the glass until
    /// it is, whatever the layers and the timing say.
    pub fn clocked(self: *const Syscnt) bool {
        return self.panel_clk & clock.enable != 0;
    }

    /// Where the pixel clock is taken from.
    pub fn source(self: *const Syscnt) Source {
        return @fromBackingInt(@intCast(self.panel_clk >> clock.source_shift & clock.source_mask));
    }

    /// The divider the clock is taken through. Zero means the field was
    /// never written, which the driver never leaves it at.
    pub fn divider(self: *const Syscnt) u32 {
        return self.panel_clk & clock.divider_mask;
    }

    /// A frame is about to be scanned. False when the pixel clock was never
    /// started, in which case the panel stays dark and the refusal is kept.
    pub fn startFrame(self: *Syscnt) bool {
        if (self.clocked()) return true;
        self.unclocked +%= 1;
        return false;
    }

    /// A frame reached the panel: raise VPOS if it is armed, and count the
    /// frame either way.
    pub fn completeFrame(self: *Syscnt) void {
        self.frames +%= 1;
        if (!self.raise(state.vpos)) self.undetected +%= 1;
    }

    /// A graphics layer could not deliver its pixels in time.
    pub fn underflow(self: *Syscnt, layer: u8) void {
        self.underflows +%= 1;
        _ = self.raise(state.underflowOf(layer));
    }

    /// Put a state into the status word if it is armed. False when the
    /// detection is disarmed, in which case silicon reports nothing at all.
    fn raise(self: *Syscnt, bit: u32) bool {
        if (self.detect & bit == 0) return false;
        if (self.status & bit == 0) self.detections +%= 1;
        self.status |= bit;
        if (self.interrupts & bit != 0) self.interrupts_due +%= 1;
        return true;
    }

    /// The states that are up and enabled, which is what would drive the
    /// interrupt line. Nothing in this tree routes a GLCDC event to the ICU
    /// yet, so this is reported rather than pended.
    pub fn pending(self: *const Syscnt) u32 {
        return self.status & self.interrupts;
    }
};
