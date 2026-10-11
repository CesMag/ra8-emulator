//! AIRCR: the software reset a firmware asks for, and the key that gates it.
//!
//! `ra8_reset_software_reset` (and CMSIS `NVIC_SystemReset` under it) ends the
//! same way every time: store `0x05FA` in the top half of AIRCR together with
//! SYSRESETREQ, then spin in a `for (;;)` waiting for the part to go away. The
//! PPB is plain RAM here, so that store landed in a word nothing read and the
//! firmware span out the rest of its budget in the wait loop.
//!
//! This block is the watcher dev keeps in emu_exc_scs.c, moved to the seam the
//! rest of this tree uses for the PPB: the clocks and the interrupt controller
//! already read and write SCB words at the chunk boundary, so AIRCR is polled
//! there too rather than hooked per access. The cost is that a write is noticed
//! at the end of the chunk it happened in, and two writes inside one chunk are
//! seen as one. The reset request is the only thing here that has to be prompt,
//! and a chunk early or late makes no difference to it.
//!
//!   AIRCR 0xE000_ED0C (DDI0553 D1.2.6)
//!     VECTKEY     [31:16] write:  must be 0x05FA or the whole write is dropped
//!     VECTKEYSTAT [31:16] read:   always 0xFA05, never what was written
//!     PRIGROUP    [10:8]  retained, read/write
//!     SYSRESETREQ [2]     write-only, asks the system for a reset
//!     VECTCLRACTIVE [1]   write-only, and not modelled beyond being dropped
const memmap = @import("../../core/memmap.zig");
pub const bank = @import("bank.zig");

/// The two halves of the key: what a write must carry, and what a read gives
/// back. They are byte-swapped versions of each other on purpose, so a driver
/// that feeds a read-back value straight into a write never unlocks anything.
pub const key = struct {
    pub const shift: u5 = 16;
    pub const write: u32 = 0x05FA;
    pub const read: u32 = 0xFA05;
    pub const mask: u32 = 0xFFFF_0000;

    /// What the register reads as with no group programmed: the key status
    /// half and nothing else. This is AIRCR's reset value on a little-endian
    /// part (ENDIANNESS reads zero).
    pub const status: u32 = read << shift;
};

pub const field = struct {
    /// VECTCLRACTIVE[1]: write-only, and only meaningful in debug halt.
    pub const vectclractive: u32 = 1 << 1;
    /// SYSRESETREQ[2]: ask the system for a reset.
    pub const sysresetreq: u32 = 1 << 2;
    /// SYSRESETREQS[3]: whether a Non-secure reset request is honoured.
    pub const sysresetreqs: u32 = 1 << 3;
    /// PRIGROUP[10:8]: the split between group and sub-priority.
    pub const prigroup: u32 = 0x0000_0700;
    /// BFHFNMINS[13] and PRIS[14]: the Secure-side configuration bits.
    pub const bfhfnmins: u32 = 1 << 13;
    pub const pris: u32 = 1 << 14;
    /// Everything the register actually holds between writes. The reset
    /// request and VECTCLRACTIVE are write-only: they take effect and are
    /// gone, so neither survives into the next read.
    pub const retained: u32 = prigroup | sysresetreqs | bfhfnmins | pris;
};

/// The AIRCR model: what the register reads as, and what the firmware has
/// been asking it for.
///
/// `held` is the architectural read-back, which is also how a write is
/// detected: the poll compares the PPB word against it, and anything else is
/// something the firmware stored since the last boundary.
pub const Scb = struct {
    held: u32 = key.status,
    /// Writes the firmware made that this model had to decide about.
    writes: u32 = 0,
    /// Writes dropped for a missing or wrong VECTKEY.
    rejected: u32 = 0,
    /// Honoured SYSRESETREQ requests.
    requests: u32 = 0,

    pub fn init() Scb {
        return .{};
    }

    /// A run whose firmware never wrote AIRCR stays out of the report.
    pub fn quiet(self: *const Scb) bool {
        return self.writes == 0;
    }

    /// Put the reset value in the PPB word, so the first read is the key
    /// status rather than the zero the mapping starts at.
    pub fn prime(self: *Scb, core: anytype) !void {
        try core.writeWord(memmap.scb.aircr, self.held);
    }

    /// Look at AIRCR, decide what the write meant, and leave the register
    /// reading the way silicon would leave it. Returns whether the firmware
    /// asked for a reset.
    pub fn poll(self: *Scb, core: anytype) !bool {
        const word = try core.readWord(memmap.scb.aircr);
        if (word == self.held) return false;
        self.writes +%= 1;
        if (word & key.mask != key.write << key.shift) {
            // No key, wrong key, or a key read back out of the register and
            // written straight in again: silicon discards the whole word.
            self.rejected +%= 1;
            try core.writeWord(memmap.scb.aircr, self.held);
            return false;
        }
        self.held = key.status | (word & field.retained);
        try core.writeWord(memmap.scb.aircr, self.held);
        if (word & field.sysresetreq == 0) return false;
        self.requests +%= 1;
        return true;
    }

    /// The priority split the firmware programmed, as the field value.
    pub fn priorityGroup(self: *const Scb) u3 {
        return @intCast((self.held & field.prigroup) >> 8);
    }
};
