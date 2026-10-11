//! Write-one-to-clear on CFSR, HFSR, SFSR and AFSR.
//!
//! Every bit in CFSR (0xE000_ED28), HFSR (0xE000_ED2C) and SFSR
//! (0xE000_EDE4) is cleared by writing a one to it, and a zero leaves it
//! alone (DDI0553 D1.2.11, D1.2.12, and SFSR in the Security Extension). A fault handler acknowledges a fault with `CFSR = CFSR`: it
//! writes back exactly the bits it read, and they go down. The PPB here is
//! plain RAM, so that store leaves the word exactly as it was, and the
//! handler that checks the status went down reads the same fault forever.
//!
//! The write hook sees each store before it lands, so it cannot rewrite the
//! word itself: the store would overwrite whatever it put there. It latches
//! the store here instead, and the latch is applied at the next chunk
//! boundary, where the PPB is polled anyway. Until then a read of the word
//! returns what the firmware wrote. That window is at most one stretch.
//!
//! A stretch can hold several stores, and nothing on this board sets a
//! fault bit inside one: the MPU's synthesised faults are latched at the
//! boundary. So the word owed is the one from before the first store, less
//! every bit any of the stores wrote. A bit that came up after the last
//! store (one the boundary set before this latch was applied) is kept.
//!
//! Byte and halfword stores are honoured lane by lane, because CMSIS
//! reaches MMFSR, BFSR and UFSR as byte, byte and halfword registers.

const memmap = @import("../../core/memmap.zig");

/// The Secure Fault Status Register. src/chip/periph/secure_fault.zig raises
/// into it; it lives here so the store hook can watch it without pulling
/// the fault routing into the core.
pub const sfsr: u32 = 0xE000_EDE4;

/// One status word's owed clear.
pub const Pending = struct {
    /// The word as it stood before the first store this stretch.
    before: u32 = 0,
    /// Every bit any store wrote a one to.
    clear: u32 = 0,
    /// The word as the last store left it in RAM.
    stored: u32 = 0,
    dirty: bool = false,
};

pub const Clears = struct {
    cfsr: Pending = .{},
    hfsr: Pending = .{},
    sfsr: Pending = .{},
    afsr: Pending = .{},
    /// How many stores were latched, for a report or a test to read.
    stores: u32 = 0,

    pub fn init() Clears {
        return .{};
    }

    /// The pending clear a store at `address` belongs to, or null when the
    /// address is not one of the status words.
    pub fn slot(self: *Clears, address: u32) ?*Pending {
        return switch (address & ~@as(u32, 3)) {
            memmap.scb.cfsr => &self.cfsr,
            memmap.scb.hfsr => &self.hfsr,
            sfsr => &self.sfsr,
            memmap.scb.afsr => &self.afsr,
            else => null,
        };
    }

    /// Latch one store of `size` bytes at `address`, with `standing` the
    /// whole word as it reads before the store lands.
    pub fn record(self: *Clears, address: u32, size: u32, value: u32, standing: u32) void {
        const pending = self.slot(address) orelse return;
        const shift: u5 = @intCast((address & 3) * 8);
        const lanes = laneMask(size) << shift;
        const written = (value << shift) & lanes;
        if (!pending.dirty) {
            pending.before = standing;
            pending.dirty = true;
        }
        pending.clear |= written;
        pending.stored = (standing & ~lanes) | written;
        self.stores +%= 1;
    }

    /// Write the owed words back and forget the latch.
    pub fn apply(self: *Clears, core: anytype) !void {
        try settle(&self.cfsr, core, memmap.scb.cfsr);
        try settle(&self.hfsr, core, memmap.scb.hfsr);
        try settle(&self.sfsr, core, sfsr);
        try settle(&self.afsr, core, memmap.scb.afsr);
    }
};

fn settle(pending: *Pending, core: anytype, address: u32) !void {
    if (!pending.dirty) return;
    const now = try core.readWord(address);
    const raised_since = now & ~pending.stored;
    try core.writeWord(address, (pending.before & ~pending.clear) | raised_since);
    pending.* = .{};
}

fn laneMask(size: u32) u32 {
    return switch (size) {
        1 => 0x0000_00FF,
        2 => 0x0000_FFFF,
        else => 0xFFFF_FFFF,
    };
}
