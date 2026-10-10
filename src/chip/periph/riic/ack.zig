//! ICMR3's ACKBT write protection (HUM Ch 39.2.5 "ICMR3 : I2C Bus Mode
//! Register 3", p 2376).
//!
//! ACKBT picks the acknowledge bit the controller sends back, and it is the
//! one bit in ICMR3 that is write-protected: ACKWP has to be in force before
//! a store can move it. HUM Ch 39.2.5 Note 1 is explicit that the
//! write-enable, the ACKBT set and the write-disable are three separate
//! register writes, and ra8_i2c.c's internal_i2c_set_nack does exactly that,
//! citing the note by page.
//!
//! dev kept the whole ICMR3 byte as a plain shadow with no protection on it
//! at all, so a driver that folded the enable and the NACK into one store got
//! the NACK here and does not get it on silicon, where the enable is not in
//! force until the access that carries it has finished. The bit then reads
//! back set, which is how a read-modify-write driver carries the wrong
//! acknowledge into the next byte it clocks.
//!
//! THE ENABLE MUST BE IN FORCE BEFORE THE ACCESS, NOT IN IT. That is the
//! whole rule, and it is what makes the three writes three. A store that
//! carries ACKWP does whatever it likes to the rest of ICMR3; it just cannot
//! move ACKBT in the same breath.
//!
//! BOTH DIRECTIONS. ACKWP is named a write protect, not a set-enable, so a
//! store that clears ACKBT without the enable in force is refused the same
//! way. WAIT, RDRFS, SMBS and the rest of ICMR3 are not protected and are
//! left alone; ACKBR is the receive side's own answer and this rule does not
//! reach it.
const flag = @import("flags.zig");

pub const Ack = struct {
    /// Stores that tried to move ACKBT with ACKWP not yet in force. Silicon
    /// leaves the bit where it was; dev moved it.
    protected: u32 = 0,

    /// The byte ICMR3 actually takes. `held` is what the register read back
    /// before this access, so the enable it carries is the one already in
    /// force.
    pub fn apply(self: *Ack, held: u8, value: u8) u8 {
        const enabled = held & flag.icmr3.ackwp != 0;
        const moves = (held ^ value) & flag.icmr3.ackbt != 0;
        if (enabled or !moves) return value;
        self.protected +%= 1;
        return (value & ~flag.icmr3.ackbt) | (held & flag.icmr3.ackbt);
    }

    pub fn quiet(self: *const Ack) bool {
        return self.protected == 0;
    }
};
