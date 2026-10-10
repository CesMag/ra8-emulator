//! Host-driven pin edges reaching the ICU (RA8EMU-375).
//!
//! The user switches are driven from the host stream (RA8EMU-344), which
//! moves the pin but cannot pend anything on its own: on the part a pin only
//! feeds its IRQ channel while its PmnPFS.ISEL bit is set (HUM Ch 20,
//! PmnPFS b14), and the channel only fires on the sense IRQCRi.IRQMD picked
//! (HUM Ch 14.2.12): 00 falling, 01 rising, 10 both edges, 11 low level.
//!
//! So the host side queues each real level change as an Edge, and the board
//! boundary asks this file whether that edge fires before raising the
//! channel's event through the usual event path (links, DTC, then the ICU).
//!
//! LOW LEVEL is taken as a raise when the pin goes low. The IR latch then
//! holds the line until the handler clears it; a level still held after
//! that clear is not raised again. Nothing in the corpus selects low level
//! (the board code picks falling edge), so this stays the simple reading.
const pfs = @import("../pfs/pfs.zig");
const irqcr = @import("irqcr.zig");

/// PmnPFS.ISEL: the pin is an IRQ input.
pub const isel: u32 = 1 << 14;

/// Edges one boundary can hold. More are dropped and counted.
pub const capacity: usize = 8;

/// IRQCRi.IRQMD values.
pub const sense = struct {
    pub const falling: u8 = 0;
    pub const rising: u8 = 1;
    pub const both: u8 = 2;
    pub const low: u8 = 3;
};

/// One level change on a pin wired to an IRQ channel.
pub const Edge = struct {
    channel: u8,
    port: u8,
    pin: u4,
    falling: bool,
};

/// The edges waiting for the next boundary.
pub const Queue = struct {
    edges: [capacity]Edge = undefined,
    len: usize = 0,
    dropped: u32 = 0,

    pub fn push(self: *Queue, edge: Edge) void {
        if (self.len == capacity) {
            self.dropped +%= 1;
            return;
        }
        self.edges[self.len] = edge;
        self.len += 1;
    }

    /// Every queued edge, emptying the queue. The slice is valid until the
    /// next push.
    pub fn take(self: *Queue) []const Edge {
        const out = self.edges[0..self.len];
        self.len = 0;
        return out;
    }
};

/// Whether an edge in this direction matches the channel's IRQMD.
pub fn senses(mode: u8, falling: bool) bool {
    return switch (mode & irqcr.field.irqmd) {
        sense.falling, sense.low => falling,
        sense.rising => !falling,
        else => true,
    };
}

/// Whether the edge raises its channel's event: ISEL set on the pin and the
/// direction matching the channel's sense.
pub fn fires(pins: *const pfs.Pfs, modes: *const irqcr.Irqcr, edge: Edge) bool {
    if (pins.pin(edge.port, edge.pin) & isel == 0) return false;
    return senses(modes.pins[edge.channel], edge.falling);
}

/// The ICU event the edge's channel raises.
pub fn eventOf(edge: Edge) u16 {
    return irqcr.eventFor(edge.channel);
}
