//! The WDT's three control registers take one write each after reset.
//!
//! HUM Ch 27.3.2 is called "Controlling Writes to the WDTCR, WDTRCR, and
//! WDTCSTPR Registers", and what it controls is how many: one apiece, after
//! which the register is deaf for the rest of the run. ra8_wdt.h states the
//! same rule against `ra8_wdt_init` in so many words, "The WDT control
//! registers can only be written once after reset (HUM Ch 27.3.2 ...), so
//! subsequent calls have no effect", and ra8_wdt.c repeats it in its own file
//! header: the driver "writes WDTCR / WDTRCR / WDTCSTPR exactly once and then
//! refreshes WDTRR to arm the counter".
//!
//! The refresh register is not one of the three and is not tracked here: a
//! watchdog would be useless if it were.
//!
//! This is a latch, not a lock with a key: nothing in the block reopens it.
//! Only a reset does, and a reset builds a new unit.

/// The three registers the rule covers, in offset order.
pub const Register = enum(u2) {
    /// WDTCR at +0x02: timeout, divider and the refresh window.
    control,
    /// WDTRCR at +0x06: reset or NMI on underflow.
    reset_control,
    /// WDTCSTPR at +0x08: whether the counter halts in Sleep.
    count_stop,
};

/// Which of the three have been written since reset.
pub const Once = struct {
    written: u3 = 0,

    fn bitOf(which: Register) u3 {
        return @as(u3, 1) << @backingInt(which);
    }

    /// True once this register has had its one write.
    pub fn taken(self: Once, which: Register) bool {
        return self.written & bitOf(which) != 0;
    }

    /// Ask for this register's one write. True the first time and false
    /// every time after, which is the caller's signal to drop the store.
    pub fn claim(self: *Once, which: Register) bool {
        if (self.taken(which)) return false;
        self.written |= bitOf(which);
        return true;
    }

    /// True while no control register has been programmed at all.
    pub fn quiet(self: Once) bool {
        return self.written == 0;
    }
};
