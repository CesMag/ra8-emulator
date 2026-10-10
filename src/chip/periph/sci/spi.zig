//! Simple-SPI mode on an SCI_B channel: which CCR3 selects it, and what a
//! transmitted frame clocks back.
//!
//! A CHANNEL IN SIMPLE-SPI MODE IS FULL DUPLEX, AND THAT IS THE WHOLE POINT
//! OF THIS FILE. In asynchronous mode the transmitter and the receiver are
//! independent: firmware sends a character, and a character comes back only
//! when something on the line sends one. In clock-synchronous and Simple-SPI
//! mode (CCR3.MOD = 011b) the channel drives the clock, so every frame it
//! transmits shifts one in at the same time, whether or not anything is
//! listening. ra8_sci_spi.c says so in its own header ("in clock-synchronous
//! / Simple-SPI mode every transmitted frame clocks one in") and its transfer
//! is exactly that: write TDR, wait for CSR.TDRE, then wait for CSR.RDRF and
//! read RDR.
//!
//! SO AN UNANSWERED FRAME IS NOT A SILENT ONE. src/chip/periph/sci/sci.zig used to
//! queue a received byte only when a device was attached to the channel's
//! line, which is right for a UART and wrong here: with nothing on the bus,
//! RDRF never rose, and the driver's `ra8_hw_wait_flag_set32(&reg->CSR,
//! rdrf, ...)` sat on that flag until its budget ran out, once per frame,
//! forever. Three images in this corpus (epub_open, epub_toc, pagecache)
//! spent 8.65 MILLION peripheral reads there, all of them the same poll of
//! SCI0's CSR, and stopped at the instruction budget having reached nothing.
//!
//! WHAT AN IDLE LINE CARRIES IS 0xFF. CIPO is pulled high on the Pmod2 SD
//! slot, as it is on every SPI bus this board carries, so a frame clocked
//! against no device reads back all ones. That is also exactly what an SD
//! card in SPI mode drives while it is not answering, so a card-detect
//! sequence run against an empty slot gets the 0xFF it expects, times out
//! through ra8_sdmmc_spi's own no-card path, and reports no card instead of
//! wedging the run. This file invents no card: it puts the idle level of an
//! unconnected line on the receiver, nothing more.
//!
//! A DEVICE ON THE LINE STILL WINS. When something is attached (the modem on
//! SCI7, a card or panel model on an SPI channel) its answer is the byte that
//! comes back, and this file does not touch the exchange. The idle byte is
//! only for a frame nothing answered.
//!
//! NOT MODELLED, AND NOT GUESSED: the rest of CCR3. CKE, CPOL, CPHA, LSBF
//! and CHR select a clock source, an edge, a bit order and a frame width,
//! none of which change what this model moves: a byte goes out and a byte
//! comes back whatever edge silicon would have used. CCR3 is kept as a
//! shadow so the mode field can be read out of it, and the other fields read
//! back what firmware wrote.

/// CCR3 sits at +0x14 in a channel's window, above CCR1 (+0x0C) and CCR2
/// (+0x10), which is where a reading of the register list alone puts it by
/// mistake (HUM Ch 38.2.8 p 2203, r_sci_regs_t in ra8_sci_regs.h).
pub const off_ccr3: u32 = 0x14;

/// The MOD field: three bits at 16, selecting the channel's mode
/// (k_ra8_sci_ccr3_shift_mod = 16, k_ra8_sci_ccr3_mask_mod = 0x0007_0000,
/// k_ra8_sci_ccr3_mod_simple_spi = 0x3).
pub const mod = struct {
    pub const shift: u5 = 16;
    pub const mask: u32 = 0x7;
    pub const simple_spi: u32 = 0b011;
};

/// What an unconnected CIPO reads back: all ones.
pub const idle_byte: u8 = 0xFF;

/// Is this channel in Simple-SPI mode, the one mode in which a transmitted
/// frame clocks a frame in on its own?
pub fn simpleSpi(ccr3: u32) bool {
    return (ccr3 >> mod.shift) & mod.mask == mod.simple_spi;
}
