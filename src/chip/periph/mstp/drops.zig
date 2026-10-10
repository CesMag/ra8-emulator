//! What the module-stop gate dropped, kept per peripheral.
//!
//! The counters alone cannot tell two very different runs apart. A driver
//! that never cancels module stop touches a dead window and keeps going: the
//! reads give zero on silicon and the writes vanish, and the run should say
//! so loudly. An image that deliberately pokes a stopped window to prove it
//! is dead, then clears the bit and carries on, dropped exactly the same
//! accesses and did nothing wrong at all.
//!
//! What separates them is not the access, it is the gate afterwards. So the
//! drops are recorded per peripheral with one address inside that peripheral
//! kept alongside them, and at the end of the run the gate is asked again:
//! a peripheral still stopped is the bug, one since ungated was the probe.
const std = @import("std");

/// One peripheral that the gate refused, and how much it refused.
pub const Entry = struct {
    /// The family name, as the report prints it.
    name: []const u8,
    /// An address inside that peripheral, so the gate can be asked about it
    /// again once the run is over.
    address: u32,
    reads: u32 = 0,
    writes: u32 = 0,
};

/// Room for one entry per gated family. A run that overflows this keeps its
/// counts in `reads`/`writes` and loses only the per-peripheral split, which
/// is the part that was not there before.
pub const capacity: usize = 32;

/// What the whole log says about a run, once the gate has been consulted.
pub const Verdict = struct {
    /// Accesses dropped on a peripheral that is still stopped now.
    stopped_reads: u32 = 0,
    stopped_writes: u32 = 0,
    /// Accesses dropped on a peripheral the firmware ungated afterwards.
    probed_reads: u32 = 0,
    probed_writes: u32 = 0,
    /// The last peripheral in each group, for the line the report prints.
    last_stopped: []const u8 = "-",
    last_probed: []const u8 = "-",

    pub fn anyStopped(self: Verdict) bool {
        return self.stopped_reads != 0 or self.stopped_writes != 0;
    }

    pub fn anyProbed(self: Verdict) bool {
        return self.probed_reads != 0 or self.probed_writes != 0;
    }
};

/// Whether a peripheral is still unclocked, asked of whoever holds the gate.
pub const StillStopped = *const fn (context: *const anyopaque, address: u32) bool;

pub const Log = struct {
    entries: [capacity]Entry = @splat(.{ .name = "", .address = 0 }),
    len: usize = 0,
    /// Drops that arrived after the table was full: counted, not split.
    overflow_reads: u32 = 0,
    overflow_writes: u32 = 0,

    pub fn empty(self: *const Log) bool {
        return self.len == 0 and self.overflow_reads == 0 and self.overflow_writes == 0;
    }

    pub fn noteRead(self: *Log, name: []const u8, address: u32) void {
        if (self.slot(name, address)) |entry| entry.reads +%= 1 else self.overflow_reads +%= 1;
    }

    pub fn noteWrite(self: *Log, name: []const u8, address: u32) void {
        if (self.slot(name, address)) |entry| entry.writes +%= 1 else self.overflow_writes +%= 1;
    }

    /// The entry for a peripheral, adding one the first time it is refused.
    fn slot(self: *Log, name: []const u8, address: u32) ?*Entry {
        for (self.entries[0..self.len]) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        if (self.len >= capacity) return null;
        self.entries[self.len] = .{ .name = name, .address = address };
        self.len += 1;
        return &self.entries[self.len - 1];
    }

    /// Split the drops by whether the gate is still closed over them. The
    /// overflow, which has no address to ask about, is read as still stopped:
    /// the loud answer is the safe one for a drop nothing can place.
    pub fn verdict(self: *const Log, context: *const anyopaque, gate: StillStopped) Verdict {
        var out = Verdict{};
        for (self.entries[0..self.len]) |entry| {
            if (gate(context, entry.address)) {
                out.stopped_reads +%= entry.reads;
                out.stopped_writes +%= entry.writes;
                out.last_stopped = entry.name;
            } else {
                out.probed_reads +%= entry.reads;
                out.probed_writes +%= entry.writes;
                out.last_probed = entry.name;
            }
        }
        out.stopped_reads +%= self.overflow_reads;
        out.stopped_writes +%= self.overflow_writes;
        return out;
    }
};
