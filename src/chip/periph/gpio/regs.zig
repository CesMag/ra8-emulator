//! The register map of one PORT instance, and what an access of each width
//! names inside it.
//!
//! Split out of src/chip/periph/gpio/gpio.zig, which owns the pins, the board LEDs and
//! the externally-driven inputs. This file owns the map alone: which word an
//! offset lands in, which 16-bit half an access names, and which of those
//! halves the port itself owns so a store to one is a refusal.
//!
//! EVERY PCNTR WORD IS A PAIR OF 16-BIT REGISTERS, AND FIRMWARE USES BOTH
//! NAMES. The RA8 header declares the four combined words and, in the same
//! union, the eight halves they are made of (HUM Ch 20.2 p 730-736,
//! ra8_port_regs.h):
//!
//!   0x00 PCNTR1 = {PODR[31:16], PDR[15:0]}   0x00 PDR   0x02 PODR
//!   0x04 PCNTR2 = {EIDR[31:16], PIDR[15:0]}  0x04 PIDR  0x06 EIDR
//!   0x08 PCNTR3 = {PORR[31:16], POSR[15:0]}  0x08 POSR  0x0A PORR
//!   0x0C PCNTR4 = {EORR[31:16], EOSR[15:0]}  0x0C EOSR  0x0E EORR
//!
//! `R_PORT6->PODR |= bit` is a halfword access at +0x02, and it is how most
//! hand-written board code drives a pin. gpio.zig used to switch on the raw
//! byte offset of an access and ignore its width, so only a 32-bit access
//! aimed at a word's first byte matched anything: the halfword at +0x02 fell
//! to `else => {}` on write and `else => 0` on read. An LED driven that way
//! never lit, a `PODR` read back to confirm the write answered zero, and the
//! run reported nothing wrong. Serving the word the access lands in and then
//! cutting it to the lanes the access names is what makes both spellings of
//! the same register agree.
//!
//! PCNTR2 IS THE PORT'S, AND A STORE TO IT IS REFUSED. PIDR is the live pin
//! level and EIDR the event input: the pads drive those, firmware does not.
//! A store there used to be dropped silently; it is refused and counted now,
//! the way this tree already treats MSTATR, MRCPS, SRAMESR, INTS and the SCI
//! status words.
//!
//! PCNTR4 STAYS AN ACCEPTED NO-OP, and that is not the same thing. The event
//! output link is genuinely writable on silicon and genuinely unmodelled
//! here, so a store is taken and forgotten rather than refused: refusing it
//! would report a driver doing something the hardware allows.

/// Offsets inside a port's 0x20 window. The four words, then the eight halves
/// they are spelled as.
pub const off = struct {
    pub const pcntr1: u32 = 0x00;
    pub const pcntr2: u32 = 0x04;
    pub const pcntr3: u32 = 0x08;
    pub const pcntr4: u32 = 0x0C;

    pub const pdr: u32 = 0x00;
    pub const podr: u32 = 0x02;
    pub const pidr: u32 = 0x04;
    pub const eidr: u32 = 0x06;
    pub const posr: u32 = 0x08;
    pub const porr: u32 = 0x0A;
    pub const eosr: u32 = 0x0C;
    pub const eorr: u32 = 0x0E;
};

pub const half_shift: u5 = 16;
pub const half_mask: u32 = 0xFFFF;

/// The word an offset lands in, which is the register that answers it however
/// narrow the access was.
pub fn word(offset: u32) u32 {
    return offset & ~@as(u32, 3);
}

/// Which byte of that word the access starts at.
pub fn lane(offset: u32) u32 {
    return offset % 4;
}

/// Whether a word is one the port itself drives, so a store to it is a
/// refusal rather than a value.
pub fn readOnly(w: u32) bool {
    return w == off.pcntr2;
}

/// The part of a 32-bit register a narrow access names.
pub fn part(value: u32, at: u32, width: u3) u32 {
    if (width >= 4) return value;
    const shift: u5 = @intCast(at * 8);
    const shifted = value >> shift;
    return if (width == 1) shifted & 0xFF else shifted & half_mask;
}

/// Fold a narrow store into a 32-bit register, leaving the bytes the access
/// does not name exactly where they were.
pub fn merge(current: u32, at: u32, width: u3, value: u32) u32 {
    if (width >= 4) return value;
    const shift: u5 = @intCast(at * 8);
    const bits: u32 = if (width == 1) 0xFF else half_mask;
    const keep = ~(bits << shift);
    return (current & keep) | ((value & bits) << shift);
}
