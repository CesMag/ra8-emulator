//! INTSELRp: which core an ICU event interrupts.
//!
//! The RA8D2 has two ICUs at one address. ICU0 belongs to CPU0 and ICU1 to
//! CPU1, and each core reaches only its own (HUM Rev 1.30, 14.2, p 526). What
//! decides which of them an event is offered to is the COMMON_ICU's interrupt
//! request select bank, 32 words at 0x4000_6040 (HUM 14.2.22, p 554):
//!
//!   INTSELRp (p = 0 to 31), +0x40 + 4p, bit i is IS(32p + i)
//!     0  the event is a CPU0 factor (the reset value)
//!     1  the event is a CPU1 factor
//!
//! Two kinds of bit are fixed at zero and ignore a store: event 0, which has
//! no factor, and the events each core already owns a copy of (88, 89, 91,
//! 92 and 101: the debug CTIs, the two IPC mutual interrupts and the FPU
//! exception). The manual also fixes the bits of event numbers the event
//! list leaves unassigned; that list is not in this tree yet, so those bits
//! still take a store here.
//!
//! This file is the register bank and the question the router asks of it.
//! Raising an event into CPU1's own link table is a later slice.
const periph = @import("../registry.zig");
const lanes = @import("../lanes.zig");

pub const base: u32 = 0x4000_6040;
pub const words: usize = 32;
pub const win_span: u32 = @intCast(words * 4);
/// One bit per event, so the bank covers every number IELS[9:0] can name.
pub const events: usize = words * 32;

pub const Core = enum { cpu0, cpu1 };

/// The event numbers whose IS bit reads zero whatever is written.
pub const fixed = [_]u16{ 0, 88, 89, 91, 92, 101 };

// One bit for each event named by HUM Rev 1.30 Table 14.5, except for the
// event 0 and the five per-core events whose INTSELR bits are separately
// fixed by HUM 14.2.22. A zero means the event number is unassigned and its
// IS bit is fixed at zero.
const assigned_writable = [_]u32{
    0xFFFFFFFE, 0x00000001, 0x84C0FFFF, 0x00E33B1F,
    0xFFFC0FFF, 0xFE5FFBDF, 0x07FFF3FF, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0xFFFFFFFF, 0x7FBFDFFF, 0xFBFDFEFF, 0x7FFFFFFF,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0xFC000000, 0x03FFFFFB, 0xFFFFFFFE, 0xFFFFFFFF,
    0xFFFFFFFF, 0xFF3FF33F, 0xFFFFFFFF, 0x0002DFDF,
    0x00FFBF3C, 0x00000000, 0x00000000, 0x00000000,
};

pub const Intsel = struct {
    bank: [words]u32 = @splat(0),

    /// Which core `event` interrupts. A number past the bank is CPU0's,
    /// the same answer the reset value gives.
    pub fn coreFor(self: *const Intsel, event: u16) Core {
        if (event >= events) return .cpu0;
        const bit = @as(u32, 1) << @intCast(event % 32);
        return if (self.bank[event / 32] & bit != 0) .cpu1 else .cpu0;
    }

    pub fn read(self: *const Intsel, address: u32, width: u3) u32 {
        const index = wordAt(address) orelse return 0;
        return lanes.part(self.bank[index], lanes.lane(address - base), width);
    }

    /// A narrow store is merged into its word first, then the fixed bits
    /// are taken back down.
    pub fn write(self: *Intsel, address: u32, width: u3, value: u32) void {
        const index = wordAt(address) orelse return;
        const merged = lanes.merge(self.bank[index], lanes.lane(address - base), width, value);
        self.bank[index] = merged & writable(index);
    }

    pub fn block(self: *Intsel) periph.Block {
        return .{
            .name = "ICU interrupt select",
            .base = base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

/// The address of INTSELRp.
pub fn wordAddress(index: usize) u32 {
    return base + 4 * @as(u32, @intCast(index));
}

/// The bits of INTSELRp that keep a store.
pub fn writable(index: usize) u32 {
    if (index >= words) return 0;
    return assigned_writable[index];
}

fn wordAt(address: u32) ?usize {
    if (address < base or address >= base + win_span) return null;
    return (address - base) / 4;
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Intsel = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Intsel = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
