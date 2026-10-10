//! Simple LIN on an SCI_B channel: the break field a commander puts on the
//! wire, and the status the responder reads back.
//!
//! The Simple LIN extension shares the channel window with the UART
//! registers (ra8_sci_regs.h, the 32-bit variant):
//!
//!   XCR0  (+0x34) TCSS[1:0] timer clock, BFE break-field enable
//!   XCR1  (+0x38) TCST break-field start, SDST start-frame detect, BMEN
//!   XCR2  (+0x3C) CF0D, CF0CE, BFLW[15:0] break-field length
//!   XSR0  (+0x5C) the detection and completion flags, read-only
//!   XSR1  (+0x60) TCNT[15:0], the bit-rate measurement capture
//!   XFCLR (+0x78) write-1-to-clear over XSR0 bits 8..15, reads back 0
//!
//! XCR1.TCST IS A STROBE, NOT A SETTING. ra8_sci_lin_send_break writes
//! `1 << k_ra8_sci_xcr1_bit_tcst` and then spins on
//! `ra8_hw_wait_flag_clear32(&reg->XCR1, mask, k_ra8_hw_budget_long)`,
//! because "TCST holds 1 during break output and clears on completion"
//! (HUM Ch 38.2.15 p 2223, quoted at ra8_sci_lin.c:189).
//!
//! Until now the whole LIN window fell through sci.zig's `else => {}` on the
//! store side and `else => 0` on the read side. Every store was dropped and
//! every read answered zero, which is the WORST direction for this register:
//! TCST read back clear on the first poll, so the spin succeeded, and
//! ra8_sci_lin_send_break returned k_ra8_ok for a break field that was never
//! generated. ra8_sci_lin_send_header builds on that and then clocks SYNC
//! and the PID out through ra8_sci_putc_polling, so a run reported a whole
//! LIN header delivered when only its two UART bytes had happened. Nothing
//! in the report said otherwise, because the break was not a byte and never
//! reached a counter. The configuration went the same way: XCR0 and XCR2
//! were dropped, so the break-field length and the timer clock
//! internal_lin_program_mode wrote read back as zero.
//!
//! THE BREAK COMPLETES INSIDE THE STORE, the way this file's UART half
//! already drains the transmitter: there is no baud-rate clock in an
//! instruction-stepped emulator, so the dominant time XCR2.BFLW asks for
//! cannot be waited out. TCST is therefore spent on the store, the break is
//! counted, and XSR0.BFOF latches the way the completion flag does on
//! silicon. That makes the driver's poll succeed because a break really
//! happened rather than because nothing did.
//!
//! GATED ON XCR0.BFE, which is the break-field enable, and refused and
//! counted when it is clear. Same cut as the UART side's CCR0.TE gate: a
//! frame the block was never enabled to send is not sent.
//! internal_lin_program_mode sets BFE at init (ra8_sci_lin.c:142) and
//! ra8_sci_lin_send_break never pulses TCST without it, so this catches a
//! driver that skipped bring-up rather than one doing its job.
//!
//! NOT MODELLED, AND NOT GUESSED. There is no LIN peer on any channel's
//! line in this tree, so nothing drives a break field INTO the block: the
//! responder flags (XSR0.BFDF, AEDF, SFSF, the compare matches) stay clear,
//! and XSR1.TCNT reads zero rather than a measurement invented out of
//! XCR0.TCSS. A responder polling BFDF waits forever here, which is the
//! honest answer for a bus with nobody on it, and it is what the report
//! says. The break is also not fed to whatever device sits on the channel's
//! line: a break field is a dominant level, not a byte, and handing a
//! stand-in byte to the AT modem would put wire data there that no silicon
//! would send.

const lanes = @import("../lanes.zig");

/// The LIN registers' offsets inside a channel (ra8_sci_regs.h).
pub const off = struct {
    pub const xcr0: u32 = 0x34;
    pub const xcr1: u32 = 0x38;
    pub const xcr2: u32 = 0x3C;
    pub const xsr0: u32 = 0x5C;
    pub const xsr1: u32 = 0x60;
    pub const xfclr: u32 = 0x78;
};

/// XCR0 (HUM Ch 38.2.14 p 2220).
pub const xcr0 = struct {
    pub const tcss: u32 = 0x0000_0003;
    /// BFE, bit 8: break-field output enable.
    pub const bfe: u32 = 0x0000_0100;
};

/// XCR1 (HUM Ch 38.2.15 p 2223).
pub const xcr1 = struct {
    /// TCST, bit 0: start break-field output. Self-clearing.
    pub const tcst: u32 = 0x0000_0001;
    pub const sdst: u32 = 0x0000_0010;
    pub const bmen: u32 = 0x0000_0020;
};

/// XCR2 (HUM Ch 38.2.16 p 2224). BFLW is the break-field length; the
/// dominant time is (BFLW + 1) timer periods, 0xFFFF is prohibited.
pub const xcr2 = struct {
    pub const bflw_shift: u5 = 16;
    pub const bflw_mask: u32 = 0xFFFF;
    pub const bflw_max: u32 = 0xFFFE;
};

/// XSR0 (HUM Ch 38.2.22 p 2235). Only BFOF is raised here; the rest are the
/// responder's, and nothing drives a break into this block.
pub const xsr0 = struct {
    /// BFOF, bit 8: break-field output completed.
    pub const bfof: u32 = 0x0000_0100;
    /// The W1C latches, bits 8..15, which XFCLR clears.
    pub const latches: u32 = 0x0000_FF00;
};

/// Whether this offset belongs to the Simple LIN half of the window.
pub fn owns(offset: u32) bool {
    return offset == off.xcr0 or offset == off.xcr1 or offset == off.xcr2 or
        offset == off.xsr0 or offset == off.xsr1 or offset == off.xfclr;
}

/// The status words, which the block owns and a store cannot fill in.
pub fn readOnly(offset: u32) bool {
    return offset == off.xsr0 or offset == off.xsr1;
}

/// What a store to XCR1 leaves behind. TCST is a command and is spent, so a
/// driver's poll for the self-clear finishes; SDST and BMEN and the compare
/// fields are settings and stay.
pub fn stored(value: u32) u32 {
    return value & ~xcr1.tcst;
}

/// The break-field length XCR2.BFLW asks for, in timer periods: the field
/// plus one, as the HUM states it.
pub fn breakLength(shadow: u32) u32 {
    return ((shadow >> xcr2.bflw_shift) & xcr2.bflw_mask) + 1;
}

/// The Simple LIN half of one channel.
pub const Lin = struct {
    /// XCR0, XCR1 and XCR2 as written, for the read back.
    control: [3]u32 = .{ 0, 0, 0 },
    /// XSR0's latched flags.
    status: u32 = 0,
    /// Break fields put on the wire.
    breaks: u32 = 0,
    /// TCST pulses refused because XCR0.BFE was clear.
    unenabled: u32 = 0,
    /// Stores aimed at XSR0 or XSR1, which the block owns.
    status_stores: u32 = 0,

    pub fn quiet(self: *const Lin) bool {
        return self.breaks == 0 and self.unenabled == 0 and self.status_stores == 0;
    }

    fn slot(offset: u32) usize {
        return (offset - off.xcr0) / 4;
    }

    pub fn read(self: *const Lin, offset: u32) u32 {
        return switch (offset) {
            off.xcr0, off.xcr1, off.xcr2 => self.control[slot(offset)],
            off.xsr0 => self.status,
            // XSR1 holds TCNT, the bit-rate measurement capture. Nothing
            // drives a break field into this block, so there is nothing to
            // have measured.
            off.xsr1 => 0,
            // XFCLR is write-only and reads back zero (HUM Ch 38.2.28).
            else => 0,
        };
    }

    /// A store of any width to one of the LIN registers. A narrow store
    /// leaves the bytes it does not name where they were, and the command
    /// bit comes out of the value the ACCESS carries rather than the stored
    /// word: a byte store into XCR1's upper compare fields asks for no
    /// break, whatever TCST was left reading.
    pub fn write(self: *Lin, offset: u32, lane: u32, width: u3, value: u32) void {
        if (readOnly(offset)) {
            self.status_stores +%= 1;
            return;
        }
        const carried = value & lanes.named(lane, width);
        if (offset == off.xfclr) {
            self.status &= ~(carried & xsr0.latches);
            return;
        }
        const index = slot(offset);
        const merged = lanes.merge(self.control[index], lane, width, value);
        self.control[index] = if (offset == off.xcr1) stored(merged) else merged;
        if (offset == off.xcr1 and carried & xcr1.tcst != 0) self.sendBreak();
    }

    /// TCST asked for a break field. There is no baud-rate clock to wait it
    /// out, so it is on the wire and done by the time the store returns:
    /// counted, BFOF latched, TCST already spent by the caller.
    fn sendBreak(self: *Lin) void {
        if (self.control[slot(off.xcr0)] & xcr0.bfe == 0) {
            self.unenabled +%= 1;
            return;
        }
        self.breaks +%= 1;
        self.status |= xsr0.bfof;
    }

    /// The break-field length this channel is programmed for, in timer
    /// periods. Reported so a run says what it put on the wire.
    pub fn length(self: *const Lin) u32 {
        return breakLength(self.control[slot(off.xcr2)]);
    }
};
