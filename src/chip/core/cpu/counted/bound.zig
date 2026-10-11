//! How many more trips of a bounded poll take the path the last one took
//! (RA8EMU-602).
//!
//! The watch hands over one trip: its decoded instructions, the registers
//! before each, and how every register and RAM word moved between this
//! trip's head and the last one's (its delta). This follows each moving
//! value through the trip. MOV, ADD and SUB keep a value affine, and so
//! does a whole-word load or store of it. Anything else that touches one
//! refuses the trip: an opaque op, a byte access, an address base, BX, a
//! push, or an instruction the table does not know. A value that stood
//! still for two trips is not proof it never moves (an LSR of a counter
//! does that), which is why the trip is followed and not just compared.
//!
//! A decision can only change through the flags. A flag setter fed by a
//! moving value is fine when nothing reads its flags before the next setter
//! (dead). Otherwise it must be a CMP, ADD, SUB or MOVS of one moving
//! value against a still one; its flags then stay put until the value
//! reaches one of a few points around that still value or the sign and
//! carry boundaries. The answer is the whole trips strictly before the
//! nearest such point. CBZ and CBNZ on a moving value decide the same way
//! as a compare of it with zero, with no flags to follow (RA8EMU-610).
//!
//! This only checks that the deltas hang together through the trip's code;
//! the watch checks the concrete ones (three heads, two equal steps)
//! before it asks.
const std = @import("std");
const td = @import("../trip_decode.zig");

pub const max_words: usize = 8;
/// The largest per-trip step followed; anything faster is refused.
pub const max_delta: i64 = 0xFFFF;
pub const unbounded: u64 = std.math.maxInt(u64);

pub const Word = struct { address: u32, delta: i64 };

pub const Trace = struct {
    steps: []const td.Step,
    /// R0..R15 before each step, in the traced trip.
    regs: []const [16]u32,
    /// How each register moved from the last trip's head to this one's.
    head: [16]i64,
    /// How each RAM word that changed moved, at most `max_words` of them.
    words: []const Word,
};

const Slot = struct { address: u32, now: i64, head: i64 };

const State = struct {
    trace: Trace,
    taint: [16]i64,
    slots: [max_words]Slot = undefined,
    used: usize = 0,
    bound: u64 = unbounded,

    fn of(self: *const State, r: ?u4) i64 {
        const reg = r orelse return 0;
        return if (reg == 15) 0 else self.taint[reg];
    }

    fn find(self: *const State, address: u32, size: u3) ?usize {
        for (self.slots[0..self.used], 0..) |slot, k| {
            if (address < slot.address +% 4 and slot.address < address +% size) return k;
        }
        return null;
    }

    fn wordTaint(self: *const State, address: u32, size: u3) ?i64 {
        const k = self.find(address, size) orelse return 0;
        const slot = self.slots[k];
        if (slot.now == 0 and slot.head == 0) return 0;
        if (size != 4 or slot.address != address) return null;
        return slot.now;
    }

    fn setWord(self: *State, address: u32, size: u3, t: i64) bool {
        if (self.find(address, size)) |k| {
            if (self.slots[k].address != address or size != 4) return t == 0 and self.slots[k].now == 0;
            self.slots[k].now = t;
            return true;
        }
        if (t == 0) return true;
        if (self.used == max_words or size != 4) return false;
        self.slots[self.used] = .{ .address = address, .now = t, .head = 0 };
        self.used += 1;
        return true;
    }
};

/// Whole trips after the traced one that take its path, `unbounded` when no
/// decision depends on a moving value, or null when the trip cannot be
/// counted.
pub fn trips(trace: Trace) ?u64 {
    if (trace.steps.len == 0 or trace.steps.len != trace.regs.len) return null;
    if (trace.words.len > max_words) return null;
    if (trace.head[13] != 0 or trace.head[14] != 0 or trace.head[15] != 0) return null;
    var state = State{ .trace = trace, .taint = trace.head };
    for (trace.words) |word| {
        if (word.address % 4 != 0) return null;
        state.slots[state.used] = .{ .address = word.address, .now = word.delta, .head = word.delta };
        state.used += 1;
    }
    for (trace.steps, 0..) |_, i| {
        if (!step(&state, i)) return null;
    }
    if (!std.mem.eql(i64, &state.taint, &trace.head)) return null;
    for (state.slots[0..state.used]) |slot| {
        if (slot.now != slot.head) return null;
    }
    return state.bound;
}

fn step(self: *State, i: usize) bool {
    const s = self.trace.steps[i];
    const now = self.trace.regs[i];
    switch (s.form) {
        .unknown => return false,
        .hint, .branch, .cond_branch => {},
        .call => self.taint[14] = 0,
        .cbz => return zeroTest(self, s, now),
        .bx => return self.of(s.rm) == 0,
        .opaque_alu => {
            if (self.of(s.rn) != 0 or self.of(s.rm) != 0) return false;
            if (s.rd) |rd| self.taint[rd] = 0;
        },
        .move, .add, .sub, .compare => return arithmetic(self, i, s, now),
        .load => return load(self, s, now),
        .store => return store(self, s, now),
        .push => return push(self, s, now),
        .pop => return pop(self, s, now),
    }
    return true;
}

fn arithmetic(self: *State, i: usize, s: td.Step, now: [16]u32) bool {
    const a = if (s.form == .move) 0 else self.of(s.rn);
    const b = self.of(s.rm);
    const other: u32 = if (s.rm) |rm| now[rm] else s.imm;
    const result: i64 = switch (s.form) {
        .move => b,
        .add => a + b,
        .sub, .compare => a - b,
        else => unreachable,
    };
    if (s.sets_flags and (a != 0 or b != 0) and !dead(self.trace.steps, i)) {
        if (a != 0 and b != 0) return false;
        const moving = if (a != 0) a else b;
        const x = if (a != 0) now[s.rn.?] else other;
        const still: u32 = switch (s.form) {
            .move => 0,
            .add => 0 -% (if (a != 0) other else now[s.rn.?]),
            else => if (a != 0) other else now[s.rn.?],
        };
        if (moving > max_delta or moving < -max_delta) return false;
        self.bound = @min(self.bound, limit(x, moving, still));
    }
    if (s.form != .compare) self.taint[s.rd.?] = result;
    return true;
}

/// CBZ or CBNZ: a moving value's branch can only flip near zero.
fn zeroTest(self: *State, s: td.Step, now: [16]u32) bool {
    const moving = self.of(s.rn);
    if (moving == 0) return true;
    if (moving > max_delta or moving < -max_delta) return false;
    self.bound = @min(self.bound, limit(now[s.rn.?], moving, 0));
    return true;
}

/// Whether nothing reads the flags step `i` sets before something sets them
/// again, going round the trip.
fn dead(steps: []const td.Step, i: usize) bool {
    for (1..steps.len) |k| {
        const next = steps[(i + k) % steps.len];
        if (next.reads_flags) return false;
        if (next.sets_flags) return true;
    }
    return true;
}

/// Trips after the traced one before `x`, moving by `delta` a trip, reaches a
/// point where the flags of comparing it with `still` could change.
pub fn limit(x: u32, delta: i64, still: u32) u64 {
    if (delta == 0) return unbounded;
    const pace: u64 = @abs(delta);
    const points = [_]u32{
        still -% 1,           still,                still +% 1,
        still +% 0x7FFF_FFFF, still +% 0x8000_0000, still +% 0x8000_0001,
        0x7FFF_FFFF,          0x8000_0000,          0xFFFF_FFFF,
        0,
    };
    var best: u64 = unbounded;
    for (points) |point| {
        const dist: u64 = if (delta > 0) point -% x else x -% point;
        if (dist == 0) continue;
        best = @min(best, (dist - 1) / pace);
    }
    return best;
}

fn addressOf(s: td.Step, now: [16]u32) u32 {
    const base = now[s.rn.?];
    return if (s.post_index) base else base +% s.imm;
}

fn load(self: *State, s: td.Step, now: [16]u32) bool {
    const rd = s.rd.?;
    if (s.rn.? == 15) {
        self.taint[rd] = 0;
        return true;
    }
    if (self.of(s.rn) != 0) return false;
    const t = self.wordTaint(addressOf(s, now), s.size) orelse return false;
    if (rd == 15 and t != 0) return false;
    self.taint[rd] = t;
    return true;
}

fn store(self: *State, s: td.Step, now: [16]u32) bool {
    if (s.rn.? == 15 or self.of(s.rn) != 0) return false;
    return self.setWord(addressOf(s, now), s.size, self.of(s.rd));
}

fn push(self: *State, s: td.Step, now: [16]u32) bool {
    const list: u16 = @truncate(s.imm);
    var at = now[13] -% 4 * @as(u32, @popCount(list));
    for (0..16) |r| {
        if (list & (@as(u16, 1) << @intCast(r)) == 0) continue;
        if (self.taint[r] != 0) return false;
        if (!self.setWord(at, 4, 0)) return false;
        at +%= 4;
    }
    return true;
}

fn pop(self: *State, s: td.Step, now: [16]u32) bool {
    const list: u16 = @truncate(s.imm);
    var at = now[13];
    for (0..16) |r| {
        if (list & (@as(u16, 1) << @intCast(r)) == 0) continue;
        const t = self.wordTaint(at, 4) orelse return false;
        if (r == 15 and t != 0) return false;
        if (r != 15) self.taint[r] = t;
        at +%= 4;
    }
    return true;
}
