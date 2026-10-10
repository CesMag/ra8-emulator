//! The width and bit order of an SPI_B frame, read out of SPCMD0.
//!
//! SPDR carries a word; how much of that word leaves the channel is
//! SPCMD0's business. SPB[20:16] holds N-1 for an N-bit frame
//! (ra8_spi_regs.h, HUM Ch 43.2.7 p 2893) and the header names exactly
//! three encodings the driver programmes: 0x07 for 8 bits, 0x0F for 16 and
//! 0x1F for 32. LSBF (bit 12) decides which end of the frame goes out
//! first.
//!
//! The driver depends on both. `internal_apply_bit_width` in ra8_spi_b.c
//! rewrites SPB before a transfer and then pushes whole uint16_t or
//! uint32_t units into SPDR, and `internal_spcmd` sets LSBF from the
//! caller's config. A model that clocks eight bits whatever SPB says hands
//! a 16-bit transfer back its low byte and loses the other half, which is
//! what this file exists to stop.
//!
//! AN UNNAMED SPB ENCODING KEEPS THE EIGHT-BIT DEFAULT. HUM lists more of
//! the field than the header carries, and inventing widths for the values
//! the tree does not name would be making the numbers up. Anything outside
//! the three named encodings counts as unnamed, leaves the frame at eight
//! bits, and is reported, the way the AGT does with a count source it does
//! not recognise. A cleared field is the exception: SPCMD0 reads zero out
//! of reset, so an image that never programmes it has not selected a bad
//! width, it has selected nothing, and the default stands without a
//! complaint on the report.
//!
//! A FRAME MOVES WHOLE, SO THE ACCESS HAS TO CARRY IT. SPDR is a data
//! port, not a bag of independently addressable bits: one store clocks one
//! frame and one read takes one. An access that cannot carry the frame SPB
//! selects has no half-frame to move, so `carriedBy` decides, and spi.zig
//! refuses the access rather than clocking or eating a frame on its
//! account.
//!
//! LSB-FIRST IS ONLY VISIBLE ON THE WIRE. A loopback tie shifts out and
//! back in at the same end, so the word returns unchanged whichever way it
//! went. A device on the line clocks MSB-first, so a frame sent LSB-first
//! reaches it reversed and what it drives comes back reversed again. That
//! is the model's own reading of a headless wire, stated rather than
//! implied.
const std = @import("std");

/// Where the command registers sit in a channel's window
/// (ra8_spi_regs.h: SPCMD0 at +0x14, eight slots of four bytes).
pub const off = struct {
    pub const spcmd0: u32 = 0x14;
    pub const registers: usize = 8;
};

/// The SPCMD0 fields this file reads.
pub const field = struct {
    /// SPB[20:16], the data length, holding N-1 for an N-bit frame.
    pub const spb: u32 = 0x001F_0000;
    pub const spb_shift: u5 = 16;
    /// LSBF, bit 12.
    pub const lsbf: u32 = 0x0000_1000;
};

/// The SPB encodings ra8_spi_regs.h names.
pub const spb = struct {
    pub const eight: u32 = 0x07;
    pub const sixteen: u32 = 0x0F;
    pub const thirty_two: u32 = 0x1F;
};

/// The frame widths those encodings select.
pub const Width = enum(u6) {
    eight = 8,
    sixteen = 16,
    thirty_two = 32,

    pub fn bits(self: Width) u6 {
        return @backingInt(self);
    }

    /// The part of a word a frame this wide carries.
    pub fn mask(self: Width) u32 {
        if (self == .thirty_two) return 0xFFFF_FFFF;
        return (@as(u32, 1) << @intCast(self.bits())) - 1;
    }

    /// Whole bytes in the frame. Every named width is a byte multiple, and
    /// a byte is the unit a device on the line takes.
    pub fn bytes(self: Width) u6 {
        return self.bits() / 8;
    }
};

/// The width SPCMD0 selects, or null when the field holds an encoding the
/// tree does not name. A cleared field selects nothing, which is not the
/// same as naming a width, so it answers null too; `of` tells the two
/// apart.
pub fn widthOf(spcmd: u32) ?Width {
    return switch ((spcmd & field.spb) >> field.spb_shift) {
        spb.eight => .eight,
        spb.sixteen => .sixteen,
        spb.thirty_two => .thirty_two,
        else => null,
    };
}

/// Whether SPCMD0's data length is still at its reset value.
pub fn cleared(spcmd: u32) bool {
    return spcmd & field.spb == 0;
}

/// What SPCMD0 says a frame looks like.
pub const Frame = struct {
    width: Width = .eight,
    lsb_first: bool = false,
    /// False when SPB held a value the tree does not name and did not
    /// leave cleared, so the width above is the default standing in for a
    /// field the model could not read.
    named: bool = true,

    pub fn bits(self: Frame) u6 {
        return self.width.bits();
    }

    pub fn mask(self: Frame) u32 {
        return self.width.mask();
    }

    /// The frame as it leaves the channel: trimmed to the width, and
    /// reversed when the low bit goes out first.
    pub fn onWire(self: Frame, word: u32) u32 {
        const trimmed = word & self.mask();
        return if (self.lsb_first) reverse(trimmed, self.bits()) else trimmed;
    }

    /// The other direction, for what the line drives back.
    pub fn fromWire(self: Frame, word: u32) u32 {
        return self.onWire(word);
    }

    /// Whether an access of this width, starting at this lane of SPDR,
    /// names the whole frame. SPDR carries one frame sitting at the bottom
    /// of the register, so an access narrower than the frame cannot carry
    /// it and an access starting above lane zero does not name it. A wider
    /// access is fine: the driver reads the register and the frame is in
    /// the low bits of what it gets.
    pub fn carriedBy(self: Frame, lane: u32, width: u3) bool {
        if (lane != 0) return false;
        return @as(u16, width) * 8 >= @as(u16, self.bits());
    }
};

/// Read a channel's frame out of its SPCMD0 word.
pub fn of(spcmd: u32) Frame {
    const selected = widthOf(spcmd);
    return .{
        .width = selected orelse .eight,
        .lsb_first = spcmd & field.lsbf != 0,
        .named = selected != null or cleared(spcmd),
    };
}

/// Turn a frame end for end, so the bit that was shifted out first arrives
/// where a MSB-first receiver expects it.
pub fn reverse(word: u32, bits: u6) u32 {
    var out: u32 = 0;
    var taken: u6 = 0;
    while (taken < bits) : (taken += 1) {
        const bit = (word >> @intCast(taken)) & 1;
        out |= bit << @intCast(bits - 1 - taken);
    }
    return out;
}
