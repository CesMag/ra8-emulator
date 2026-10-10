//! The ELC routing table: the ELSR slots, and what actually reaches one.
//!
//! ELSR[n] holds the source event that peripheral slot n takes (ELS, 10 bits).
//! The slot itself is fixed silicon: which destination peripheral sits behind
//! slot n is HUM Table 19.2, and that table is not in this tree, so a
//! conducted event stops at the slot here and the slot counts it. What this
//! file does model is the part a firmware can get wrong: whether an event
//! reaches a slot at all, how many slots take the same source, and whether
//! ELCR.ELCON was set at the moment it arrived.
//!
//! Several slots may link the same event, so a lookup answers the whole set
//! rather than the first match: a firmware that starts two peripherals off
//! one timer event is doing the ordinary thing, and answering only the first
//! would silently drop the second.
const std = @import("std");
const Bounded = @import("../../core/bounded.zig").Bounded;

/// ELSR0..ELSR52 (FSP R_ELC_Type, ra8_elc.h k_ra8_elc_elsr_count).
pub const slots: usize = 53;

/// ELSR.ELS [9:0]: the source event a slot listens for.
pub const els_mask: u16 = 0x03FF;

/// The slots that take one event. Bounded by the table, because nothing stops
/// a firmware from pointing every slot at the same source.
pub const Takers = Bounded(u8, slots);

/// What happened to one event offered to the table.
pub const Arrival = enum {
    /// No slot links this event. The ordinary case: most events are nobody's
    /// ELC source.
    unrouted,
    /// At least one slot took it and the block was on.
    conducted,
    /// A slot links it, but ELCR.ELCON is clear, so nothing conducted. This
    /// is the quiet failure: the link reads back exactly as it would working.
    blocked,
};

pub const Table = struct {
    els: [slots]u16 = @splat(0),
    /// Events that reached each slot.
    arrivals: [slots]u32 = @splat(0),
    /// Events offered to the table at all.
    offered: u32 = 0,
    /// Offered events no slot links.
    unrouted: u32 = 0,
    /// Slot arrivals, counted across slots: one event taken by two slots is
    /// two here and one conduction.
    delivered: u32 = 0,
    /// Events a slot links that arrived with the block switched off.
    blocked: u32 = 0,

    pub fn latch(self: *Table, index: usize, value: u16) void {
        if (index < slots) self.els[index] = value;
    }

    pub fn source(self: *const Table, index: usize) u16 {
        return if (index < slots) self.els[index] & els_mask else 0;
    }

    /// How many slots have a source programmed.
    pub fn programmed(self: *const Table) u32 {
        var total: u32 = 0;
        for (self.els) |slot| {
            if (slot & els_mask != 0) total += 1;
        }
        return total;
    }

    /// Every slot linked to `event`. Event 0 is "link disabled", so it never
    /// matches, however many slots hold zero.
    pub fn takers(self: *const Table, event: u16) Takers {
        var found = Takers{};
        if (event == 0) return found;
        for (self.els, 0..) |slot, index| {
            if (slot & els_mask == event) found.append(@intCast(index)) catch break;
        }
        return found;
    }

    /// The first slot linked to `event`, for a caller that only needs to know
    /// whether anything is listening.
    pub fn firstTaker(self: *const Table, event: u16) ?usize {
        const found = self.takers(event);
        return if (found.len == 0) null else found.get(0);
    }

    /// Offer one event to the table. `enabled` is ELCR.ELCON, read at the
    /// moment the event arrives rather than when the link was programmed,
    /// because that is when silicon looks at it.
    pub fn offer(self: *Table, event: u16, enabled: bool) Arrival {
        self.offered +%= 1;
        const found = self.takers(event);
        if (found.len == 0) {
            self.unrouted +%= 1;
            return .unrouted;
        }
        if (!enabled) {
            self.blocked +%= 1;
            return .blocked;
        }
        for (found.constSlice()) |index| {
            self.arrivals[index] +%= 1;
            self.delivered +%= 1;
        }
        return .conducted;
    }

    /// How many events reached one slot.
    pub fn arrivalsAt(self: *const Table, index: usize) u32 {
        return if (index < slots) self.arrivals[index] else 0;
    }

    /// How many slots took at least one event.
    pub fn busySlots(self: *const Table) u32 {
        var total: u32 = 0;
        for (self.arrivals) |count| {
            if (count != 0) total += 1;
        }
        return total;
    }

    pub fn quiet(self: *const Table) bool {
        return self.programmed() == 0 and self.delivered == 0 and self.blocked == 0;
    }
};
