//! CSR, FRSR and FTSR: the SCI_B status words a polled driver lives on, and
//! what a store to one does.
//!
//! Split out of src/chip/periph/sci/sci.zig, which owns the channel, the line capture
//! and the transmit gate. This file owns the three words the controller
//! writes and firmware only reads, and the two clear strobes that sit beside
//! them.
//!
//! THE BITS THE DRIVER WANTS ARE IN THE TOP BYTE. TDRE is bit 29, TEND bit
//! 30 and RDRF bit 31, so a driver polling the transmitter with a byte load
//! reads CSR+3, and one watching RXDMON (bit 15) reads the halfword at CSR+0.
//! Those are ordinary accesses on silicon, and this file exists partly so
//! the window answers them: sci.zig used to switch on the raw byte offset,
//! so a load at CSR+3 matched no register at all and fell through to zero.
//! A `while ((REG8(CSR + 3) & TDRE) == 0)` on that answer never leaves its
//! loop, and the run dies at the instruction budget with the console silent.
//!
//! A STORE TO ONE OF THEM IS REFUSED, NOT SWALLOWED. CSR, FRSR and FTSR are
//! status: the transmitter and the FIFOs set those bits, firmware does not.
//! sci.zig used to drop such a store on the floor with the same `else => {}`
//! that serves CFCLR and FFCLR, so a driver storing CSR to force a flag was
//! told nothing and the run reported nothing. It is refused and counted
//! here, the way this tree already treats MSTATR, MRCPS, SRAMESR and INTS.
//!
//! CFCLR AND FFCLR ARE ACCEPTED, and most of what they name is a no-op.
//! They are write-1-to-clear strobes, and TDRE, TEND and RDRF are derived
//! here rather than latched: the first two never go down and the third
//! follows the receive queue, so clearing them changes nothing and refusing
//! them would report a driver doing exactly what the hardware manual asks of
//! it. ORER IS THE ONE THAT IS A LATCH, so CFCLR.ORERC is the one bit of
//! either strobe that does something.
//!
//! ORER HAS A SOURCE HERE, and it is the receive ring. The ring is a fixed
//! 512 bytes with no allocator below the bus, so a host or a device that
//! drives more than the firmware has read out loses the excess, and
//! sci.zig's Ring has always counted it. That IS an overrun: a character
//! arrived with the previous one still unread, which is what CSR.ORER
//! (bit 24, HUM Ch 38.2.17 p 2225) reports and what ra8_sci_get_errors
//! turns into k_ra8_sci_err_overrun. The bit read clear forever, so a run
//! that dropped characters told the driver its line was clean and the
//! error path was never entered: the firmware saw a short message rather
//! than a reported overrun, which is the worse of the two directions for a
//! model to be wrong in. It latches now, and only CFCLR.ORERC
//! (bit 24, HUM Ch 38.2.24 p 2238, and inside ra8_sci.c's own
//! k_ra8_sci_cfclr_default = 0x9D070010) puts it down.
//!
//! NOT MODELLED, AND NOT GUESSED: FER and PER, and the receiver halt. The
//! other two error flags have no source here, because there is no baud clock
//! to frame against and no line to see noise on, so they still read clear
//! rather than being raised on an invented fault. Nor does a raised ORER
//! stop the receiver: silicon holds the next character off until the flag is
//! cleared, and nothing in this tree states that, so the ring keeps taking
//! what fits and the flag stays up until the strobe clears it. Both are
//! their own slice if an image ever needs them.

/// The offsets this file owns inside a channel's 0x100 window.
pub const off = struct {
    pub const csr: u32 = 0x48;
    pub const frsr: u32 = 0x50;
    pub const ftsr: u32 = 0x54;
    pub const cfclr: u32 = 0x68;
    pub const ffclr: u32 = 0x70;
};

/// CSR status bits (ra8_sci_csr_bit_t).
pub const csr = struct {
    pub const rxdmon: u32 = 0x0000_8000;
    pub const orer: u32 = 0x0100_0000;
    pub const tdre: u32 = 0x2000_0000;
    pub const tend: u32 = 0x4000_0000;
    pub const rdrf: u32 = 0x8000_0000;
};

/// CFCLR clear lines. Only the one over a flag this model latches is named:
/// the rest clear derived bits and are accepted with nothing to do.
pub const cfclr = struct {
    pub const orerc: u32 = 0x0100_0000;
};

/// The bits a read of FRSR or FTSR reports.
pub const fifo = struct {
    pub const frsr_dr: u32 = 0x0000_0001;
    pub const frsr_rdf: u32 = 0x0000_0040;
    pub const ftsr_tdfe: u32 = 0x0000_0040;
};

/// CSR as firmware reads it. The transmitter is always drained in this model,
/// because there is no baud-rate clock in an instruction-stepped emulator, so
/// TDRE and TEND read set; RXDMON idles high the way an unloaded line does;
/// and RDRF is a fact about the receive queue rather than a value a driver
/// wrote.
pub fn common(readable: bool) u32 {
    const idle = csr.tdre | csr.tend | csr.rxdmon;
    return if (readable) idle | csr.rdrf else idle;
}

/// Whether a store to CFCLR asks for the overrun latch to come down. The
/// value the ACCESS carries decides it, never the register's own shadow:
/// CFCLR reads as zero, so there is no shadow to consult.
pub fn clearsOverrun(value: u32) bool {
    return value & cfclr.orerc != 0;
}

/// FRSR: the receive FIFO reports a byte waiting exactly when the queue has
/// one and the receiver is enabled to hear it.
pub fn receive(readable: bool) u32 {
    return if (readable) fifo.frsr_dr | fifo.frsr_rdf else 0;
}

/// FTSR: the transmit FIFO is always empty here, for the same reason TDRE is
/// always set.
pub const transmit: u32 = fifo.ftsr_tdfe;

/// Whether a word in the channel window is one the controller owns, so a
/// store to it is a refusal rather than a value.
pub fn readOnly(word: u32) bool {
    return word == off.csr or word == off.frsr or word == off.ftsr;
}

/// Whether a word is one of the write-1-to-clear strobes, which take a store
/// and do nothing with it.
pub fn clearStrobe(word: u32) bool {
    return word == off.cfclr or word == off.ffclr;
}
