//! A bounded poll's trips, counted once its values move by the same amount
//! every trip (RA8EMU-602).
//!
//! fixed_trip.zig retires a loop whose trip changes nothing. A counting poll
//! (internal_ns_ipc_recv counting up to 999999 while it reads a status
//! register) changes its counter every trip, so that test refuses it. The
//! recorder follows such a loop from its head: every instruction with the
//! registers before it, and the old value of every RAM word a store
//! changes. At each head it takes how far R0..R15 and those words moved.
//! Two trips that move them by the same amounts (three heads) hand the
//! second trip to counted_bound.zig, which says how many more trips take
//! the same path. `apply` then moves the registers and words on by that
//! many trips at once.
//!
//! The recorder only covers R0..R15, xPSR and RAM words. Everything else a
//! trip could change (FP state, banked registers, the exclusive monitor,
//! active exceptions) is the watch's to check, as for a fixed trip.
const std = @import("std");
const bus = @import("../bus.zig");
const td = @import("../trip_decode.zig");
const cb = @import("bound.zig");
const Regs = @import("../regs.zig").Regs;

pub const max_steps: usize = 64;

pub const Outcome = union(enum) {
    /// The loop cannot be counted; stop watching it.
    refuse,
    /// Not enough trips seen yet; keep recording.
    again,
    /// Whole trips from this head that take the traced path.
    retire: u64,
};

const Tracked = struct { address: u32, at_head: u32, delta: i64 };

pub const Recorder = struct {
    heads: u8 = 0,
    head: [16]u32 = @splat(0),
    xpsr: u32 = 0,
    deltas: [16]i64 = @splat(0),
    steps: [max_steps]td.Step = undefined,
    before: [max_steps][16]u32 = undefined,
    len: usize = 0,
    words: [cb.max_words]Tracked = undefined,
    used: usize = 0,
    broken: bool = false,

    /// At the loop head, before its first instruction.
    pub fn start(self: *Recorder, regs: *const Regs) void {
        self.* = .{ .heads = 1, .head = all(regs), .xpsr = regs.xpsr };
    }

    /// Before each instruction of a trip, the head's included.
    pub fn step(self: *Recorder, regs: *const Regs, hw1: u16, hw2: u16) void {
        if (self.len == max_steps) {
            self.broken = true;
            return;
        }
        self.steps[self.len] = td.decode(hw1, hw2);
        self.before[self.len] = all(regs);
        self.len += 1;
    }

    /// Before a store changes the aligned RAM word at `address`, holding `old`.
    pub fn store(self: *Recorder, address: u32, old: u32) void {
        for (self.words[0..self.used]) |one| {
            if (one.address == address) return;
        }
        if (self.used == cb.max_words or address % 4 != 0) {
            self.broken = true;
            return;
        }
        self.words[self.used] = .{ .address = address, .at_head = old, .delta = 0 };
        self.used += 1;
    }

    /// Back at the head after a trip.
    pub fn atHead(self: *Recorder, regs: *const Regs, memory: bus.Bus) Outcome {
        if (self.broken or self.heads == 0 or regs.xpsr != self.xpsr) return .refuse;
        const now = all(regs);
        var deltas: [16]i64 = undefined;
        for (&deltas, now, self.head) |*d, a, b| d.* = signed(a -% b);
        var moved: [cb.max_words]cb.Word = undefined;
        for (self.words[0..self.used], 0..) |*one, k| {
            const value = word(memory, one.address) orelse return .refuse;
            const d = signed(value -% one.at_head);
            if (self.heads >= 2 and d != one.delta) return .refuse;
            moved[k] = .{ .address = one.address, .delta = d };
            one.delta = d;
            one.at_head = value;
        }
        if (self.heads >= 2 and !std.mem.eql(i64, &deltas, &self.deltas)) return .refuse;
        defer {
            self.head = now;
            self.deltas = deltas;
            self.len = 0;
            self.heads +|= 1;
        }
        if (self.heads == 1) return .again;
        const trips = cb.trips(.{
            .steps = self.steps[0..self.len],
            .regs = self.before[0..self.len],
            .head = self.deltas,
            .words = moved[0..self.used],
        }) orelse return .refuse;
        return .{ .retire = trips };
    }

    /// Moves R0..R12 and the tracked words on by `trips` trips from the head
    /// `atHead` just saw. SP, LR and PC never move (counted_bound refuses).
    pub fn apply(self: *Recorder, regs: *Regs, memory: bus.Bus, trips: u64) bus.Error!void {
        const n: u32 = @truncate(trips);
        for (0..13) |r| regs.low[r] +%= unsigned(self.deltas[r]) *% n;
        for (self.words[0..self.used]) |*one| {
            one.at_head +%= unsigned(one.delta) *% n;
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, one.at_head, .little);
            try memory.write(one.address, &bytes);
        }
        self.head = all(regs);
    }
};

fn all(regs: *const Regs) [16]u32 {
    var out: [16]u32 = undefined;
    for (&out, 0..) |*one, r| one.* = regs.get(@intCast(r));
    return out;
}

fn signed(diff: u32) i64 {
    return @as(i32, @bitCast(diff));
}

fn unsigned(delta: i64) u32 {
    return @bitCast(@as(i32, @intCast(delta)));
}

fn word(memory: bus.Bus, address: u32) ?u32 {
    var bytes: [4]u8 = undefined;
    memory.read(address, &bytes) catch return null;
    return std.mem.readInt(u32, &bytes, .little);
}
