//! DTCCR.RRS: the read-skip cache, which is why an edited descriptor can go
//! unseen.
//!
//! The controller keeps no transfer state in its own registers: every
//! activation reads a sixteen-byte TI block out of RAM, moves what it says,
//! and writes it back (src/chip/periph/dtc/xfer.zig). RRS is the one exception.
//! With it set, an activation whose vector number matches the previous one
//! skips that read and works from the copy the controller is still holding.
//! Clearing RRS drops the copy, which is the only way firmware has to make
//! the controller look at RAM again.
//!
//! That is not a performance detail, it is a correctness trap, and the
//! in-tree driver is built around it: `ra8_dtc_reconfigure` stops the block,
//! rewrites DTCVBR, cleans the CPU's cache lines out to memory, and then
//! writes DTCCR twice, 0x08 then 0x18, purely so "the read-skip cache picks
//! up the fresh entries" (ra8_dtc.c). A model that stores RRS and reads from
//! RAM every time makes that toggle decoration: firmware that edits a
//! descriptor in place and forgets the toggle works here and moves stale
//! bytes on a bench.
//!
//! The two DTCCR values are 0x08 and 0x18 rather than 0x00 and 0x10 because
//! bit 3 is reserved write-as-1 (ra8_dtc_regs.h, HUM Ch 18.2.1 p 786), so the
//! enable test below masks RRS out of the byte instead of comparing it whole.
//!
//! NOT MODELLED, AND NOT GUESSED: the write-back. This block skips the READ,
//! which is what the field is named for and what the driver's comment
//! describes; neither tree says whether silicon also holds the spent
//! descriptor back from RAM while RRS is set, so it is written back on every
//! activation as before. Nor is DTCCR's reserved bit 3 forced up on readback:
//! the header calls it read-as-1, but that is a separate observable from this
//! one and belongs to its own slice.
const xfer = @import("xfer.zig");

/// DTCCR fields (ra8_dtc_regs.h).
pub const field = struct {
    /// RRS b4: skip the transfer-information read on a repeated vector.
    pub const rrs: u8 = 0x10;
    /// b3: reserved, read-as-1 and write-as-1.
    pub const reserved: u8 = 0x08;
    /// The two values FSP writes, kept so a caller can name them.
    pub const rrs_off: u8 = reserved;
    pub const rrs_on: u8 = reserved | rrs;
};

/// Whether DTCCR as written has the read skip switched on.
pub fn enabled(dtccr: u8) bool {
    return dtccr & field.rrs != 0;
}

/// Where one activation's descriptor came from.
pub const Fetch = enum {
    /// Read out of RAM: RRS clear, nothing held, or a different vector.
    memory,
    /// Taken from the held copy, so an edit made in RAM since the last
    /// activation on this vector is not seen.
    held,
};

/// The copy the controller is holding, and the counters behind it.
pub const Cache = struct {
    /// The vector the copy belongs to. Null means nothing is held.
    vector: ?u8 = null,
    info: xfer.Info = .decode(0, 0, 0, 0, 0),
    /// Activations that read RAM.
    reads: u32 = 0,
    /// Activations that skipped the read.
    skips: u32 = 0,
    /// Times a copy was thrown away because RRS went clear.
    drops: u32 = 0,

    /// A run that never activated the controller has nothing to narrate.
    pub fn quiet(self: *const Cache) bool {
        return self.reads == 0 and self.skips == 0 and self.drops == 0;
    }

    /// Whether a copy for this vector is being held.
    pub fn holds(self: *const Cache, vector: u8) bool {
        return self.vector == vector;
    }

    /// The descriptor for this activation, or null when the caller has to go
    /// to RAM for it. Counts the activation either way.
    pub fn fetch(self: *Cache, dtccr: u8, vector: u8) ?xfer.Info {
        if (enabled(dtccr) and self.holds(vector)) {
            self.skips +%= 1;
            return self.info;
        }
        self.reads +%= 1;
        return null;
    }

    /// Hold `info` as the copy for `vector`, replacing whatever was held.
    pub fn keep(self: *Cache, vector: u8, info: xfer.Info) void {
        self.vector = vector;
        self.info = info;
    }

    /// Throw the copy away. Silent when nothing was held.
    pub fn drop(self: *Cache) void {
        if (self.vector == null) return;
        self.vector = null;
        self.drops +%= 1;
    }

    /// A DTCCR write landed. Only the falling edge of RRS matters: setting it
    /// again starts from whatever the next activation reads.
    pub fn latch(self: *Cache, before: u8, after: u8) void {
        if (enabled(before) and !enabled(after)) self.drop();
    }
};
