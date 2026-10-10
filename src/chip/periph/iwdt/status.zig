//! IWDTSR: a live counter that software cannot write, beside two flags that
//! only a written zero takes off.
//!
//! The status register packs three things into sixteen bits (HUM Ch 28.2.2
//! p 1274, via ra8-firmware `ra8_iwdt_regs.h`): CNTVAL[13:0], the down-counter
//! itself, read-only; UNDFF bit 14, the underflow; and REFEF bit 15, the
//! refresh error. Both flags are write-ZERO-to-clear, the same opposite
//! polarity the WDT status register has.
//!
//! Two things go wrong when this register is a plain shadow cell. The
//! counter stops moving, so a firmware that waits for it, and the refresh
//! window in `examples/.../iwdt_demo` waits for exactly that, waits forever.
//! And the driver's own status clear, `ra8_iwdt_clear_status`, reads IWDTSR
//! and writes back the whole word with the flag bits masked off, which means
//! it writes the counter bits it just read: against a cell that accepts them
//! the counter is pinned to the moment of the last clear, and against silicon
//! they are discarded. The model discards them and counts how often it had to.
/// The three fields of IWDTSR.
pub const field = struct {
    /// CNTVAL[13:0], the live down-counter. Read-only.
    pub const cntval: u16 = 0x3FFF;
    /// UNDFF, bit 14: the counter reached zero.
    pub const undff: u16 = 0x4000;
    /// REFEF, bit 15: a refresh arrived outside the permitted window.
    pub const refef: u16 = 0x8000;
    /// Both flags.
    pub const flags: u16 = undff | refef;
};

/// What a read of IWDTSR answers: the live counter with the latched flags
/// above it.
pub fn value(counter: u16, held: u16) u16 {
    return (counter & field.cntval) | (held & field.flags);
}

/// What the flags become after a store. A zero at a held flag clears it; a
/// one leaves it standing, and cannot set one that is not held.
pub fn ack(held: u16, written: u16) u16 {
    return held & written & field.flags;
}

/// True when a store wrote a one at a flag that is standing, which clears
/// nothing. The driver's own clear writes zeros, so this is a firmware that
/// reached for write-one-to-clear.
pub fn refused(held: u16, written: u16) bool {
    return ack(held, written) != 0;
}

/// True when a store carried counter bits. They never land: CNTVAL is the
/// hardware's, and a driver that writes its own read back is not asking to
/// move it.
pub fn carriesCount(written: u16) bool {
    return written & field.cntval != 0;
}
