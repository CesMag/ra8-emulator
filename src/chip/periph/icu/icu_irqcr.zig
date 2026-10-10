//! IRQCRa/IRQCRb: the external-IRQ pins' detection sense and digital filter.
//!
//! Thirty-two external IRQ pins each get one control byte (HUM Ch 14.2.12
//! "IRQCRi : IRQ Control Register" p 535): IRQMD[1:0] picks the detection
//! sense, FCLKSEL[1:0] the filter's sampling clock, FLTEN turns the filter
//! on. The thirty-two bytes come in two runs, IRQCRa for channels 0..15 at
//! the top of R_ICU and IRQCRb for channels 16..31 four bytes past the end
//! of the first run, the gap and the offsets taken from
//! ra8_icu_regs.h's offset enum (k_ra8_icu_off_irqcra0 = 0x0000,
//! k_ra8_icu_off_irqcrb0 = 0x0014, k_ra8_icu_irqcrb_offset = 4).
//!
//! src/chip/periph/icu/icu.zig claimed only IELSR and said so in its own header: the
//! rest of the ICU was "nobody's yet". So these thirty-two bytes fell through
//! to the sparse register file, which takes any store and gives it back, and
//! the one ordering rule the part puts on them went unwatched.
//!
//! THE RULE: ra8_icu.h says over ra8_icu_configure_irq_pin that per HUM
//! 14.2.12 IRQCRi may only be rewritten while the matching IELSRn register
//! is 0, meaning while no event is routed, and that the caller must order
//! its init sequence accordingly. A firmware that changes a pin's sense or
//! filter while the ICU is still routing that pin's event is reconfiguring
//! an input the controller is actively watching.
//!
//! NOT REFUSED, AND NOT GUESSED. The manual phrases this as a prohibition
//! and nothing in this tree says what the part actually does with such a
//! store: whether it is dropped, taken late, or taken with a glitch on the
//! pin. So the store lands exactly as it always did and the run counts it,
//! the same cut the DOTF reversed-pair and OCTACLK early-release slices took
//! for prohibited states with an unstated consequence. A store that lands
//! the value already there is not a rewrite and is not counted.
//!
//! The routed question is asked of the live IELSR table rather than a copy,
//! so a firmware that unroutes the event, reconfigures, and routes it again
//! is quiet, which is the sequence the warning asks for.

/// Channel counts and where the two runs sit inside R_ICU
/// (ra8_icu_regs.h, verified there against FSP R_ICU_Type).
pub const channels: usize = 32;
pub const first_run: usize = 16;
pub const off_a: u32 = 0x0000;
pub const off_b: u32 = 0x0014;

/// The window covers both runs and the four reserved bytes between them.
pub const win_span: u32 = off_b + first_run;

/// IRQCRi fields (HUM Ch 14.2.12 p 535). Bits 2, 3 and 6 are reserved.
pub const field = struct {
    pub const irqmd: u8 = 0x03;
    pub const fclksel: u8 = 0x30;
    pub const flten: u8 = 0x80;
    pub const occupied: u8 = irqmd | fclksel | flten;
};

/// The ELC event number an IRQ channel raises. ra8_elc_regs.h gives IRQ0 as
/// event 0x001, IRQ1 as 0x002, IRQ12 as 0x00D, IRQ13 as 0x00E and IRQ15 as
/// 0x010, so the event is the channel plus one.
pub fn eventFor(channel: usize) u16 {
    return @intCast(channel + 1);
}

/// The channel a byte of this window belongs to, or null for the four
/// reserved bytes between the two runs.
pub fn channelAt(offset: u32) ?usize {
    if (offset < off_a + first_run) return @intCast(offset - off_a);
    if (offset < off_b) return null;
    if (offset < off_b + first_run) return @intCast(first_run + (offset - off_b));
    return null;
}

/// The thirty-two control bytes and the rewrites the manual forbids.
pub const Irqcr = struct {
    pins: [channels]u8 = @splat(0),
    /// Stores that changed a pin's byte while its event was routed.
    rewrites_while_routed: u32 = 0,

    /// A run that never configured a pin stays out of the report.
    pub fn quiet(self: *const Irqcr) bool {
        if (self.rewrites_while_routed != 0) return false;
        for (self.pins) |pin| {
            if (pin != 0) return false;
        }
        return true;
    }

    pub fn read(self: *const Irqcr, offset: u32) u8 {
        const channel = channelAt(offset) orelse return 0;
        return self.pins[channel];
    }

    /// Take a store. `routed` is whether the ICU currently links this
    /// channel's event to a line; the caller asks the live table, because
    /// only the owner of that table can.
    pub fn store(self: *Irqcr, offset: u32, value: u8, routed: bool) void {
        const channel = channelAt(offset) orelse return;
        const next = value & field.occupied;
        if (routed and next != self.pins[channel]) self.rewrites_while_routed +%= 1;
        self.pins[channel] = next;
    }

    /// How many pins this run configured, so the report can lead with the
    /// work before the warning.
    pub fn configured(self: *const Irqcr) usize {
        var count: usize = 0;
        for (self.pins) |pin| {
            if (pin != 0) count += 1;
        }
        return count;
    }
};

/// A pin's address, so a test does not have to redo the two-run arithmetic.
pub fn pinAddress(base: u32, channel: usize) u32 {
    if (channel < first_run) return base + off_a + @as(u32, @intCast(channel));
    return base + off_b + @as(u32, @intCast(channel - first_run));
}
