//! The PFS write-protect gate: PWPR and PWPRS, and the difference between a
//! pin the firmware programmed and a pin the write never reached.
//!
//! (R_PMISC at 0x4040_0D00, HUM Ch 20.2.6 "PWPR" and 20.2.7 "PWPRS".) A
//! PmnPFS write is gated by a two-step unlock, and both steps are needed:
//!
//!   1. write 0        clears B0WI (bit 7), which is what allows PFSWE to be
//!                     written at all
//!   2. write 1 << 6   sets PFSWE, which is what allows PmnPFS writes
//!
//! Skipping the unlock does not fault and does not report: the pin write
//! silently goes nowhere, and the driver carries on believing the pin is
//! routed. ra8_pfs_pwpr_unlock() in ra8_pfs_regs.h does exactly those four
//! stores (both the NS and the Secure path), and ra8_pfs_pwpr_lock() writes 0
//! then 1 << 7 to close it again.
//!
//! B0WI IS CHECKED AGAINST THE VALUE STANDING BEFORE THE WRITE, not against
//! the value the same store carries, so a single store that sets both bits
//! sets both. That is the reading the unlock sequence needs: it clears B0WI in
//! one store precisely so the next store can set PFSWE.
//!
//! ONLY THE SECURE PATH GATES HERE, and the reason is PMSAR. Per HUM Ch 20.2.6
//! the chip ignores whichever of PWPR / PWPRS does not own the port, and
//! R_PMISC->PMSAR decides; PMSAR resets to every port owned by Secure on the
//! RA8D2 and no firmware here programmes it. So PWPRS.PFSWE is the bit that
//! lets a pin write land. PWPR is still modelled, because the driver writes it
//! and reads it back, but it governs nothing until PMSAR is modelled too.
const std = @import("std");

pub const off = struct {
    /// PWPR: the non-secure write protect register.
    pub const pwpr: u32 = 0x00C;
    /// PWPRS: the Secure one, which is the one that gates while PMSAR is at
    /// its reset value.
    pub const pwprs: u32 = 0x014;
};

pub const field = struct {
    /// PFSWE: set to let PmnPFS writes land.
    pub const pfswe: u8 = 1 << 6;
    /// B0WI: while set, a write cannot change PFSWE.
    pub const b0wi: u8 = 1 << 7;
};

/// One write-protect register: the two bits, and how a store moves them.
pub const Gate = struct {
    /// B0WI resets set, so a pin write before any unlock goes nowhere.
    word: u8 = field.b0wi,

    /// True when PmnPFS writes are allowed through this path.
    pub fn open(self: Gate) bool {
        return self.word & field.pfswe != 0;
    }

    /// Take a store. B0WI always takes what the store carries; PFSWE takes it
    /// only when B0WI was clear beforehand, which is the whole point of the
    /// two-step sequence.
    pub fn store(self: *Gate, value: u8) void {
        const locked = self.word & field.b0wi != 0;
        var next = value & field.b0wi;
        if (locked) {
            next |= self.word & field.pfswe;
        } else {
            next |= value & field.pfswe;
        }
        self.word = next;
    }
};

/// Both paths, and what the run should say about them.
pub const Protect = struct {
    secure: Gate = .{},
    non_secure: Gate = .{},
    /// Pin writes that arrived with the Secure path still locked.
    refused: u32 = 0,
    /// Stores that tried to set PFSWE while B0WI still stood.
    ignored_keys: u32 = 0,

    pub fn quiet(self: Protect) bool {
        return self.refused == 0 and self.ignored_keys == 0;
    }

    /// Whether a PmnPFS write lands. See the header on why this is the Secure
    /// path alone.
    pub fn allows(self: Protect) bool {
        return self.secure.open();
    }

    /// Record a pin write that the gate turned away.
    pub fn refuse(self: *Protect) void {
        self.refused +%= 1;
    }

    pub fn write(self: *Protect, offset: u32, value: u8) void {
        const gate = switch (offset) {
            off.pwprs => &self.secure,
            else => &self.non_secure,
        };
        const was = gate.word;
        gate.store(value);
        const wanted = value & field.pfswe != 0;
        const landed = gate.word & field.pfswe != 0;
        if (wanted and !landed and was & field.b0wi != 0) self.ignored_keys +%= 1;
    }

    pub fn read(self: Protect, offset: u32) u8 {
        return switch (offset) {
            off.pwprs => self.secure.word,
            else => self.non_secure.word,
        };
    }
};
