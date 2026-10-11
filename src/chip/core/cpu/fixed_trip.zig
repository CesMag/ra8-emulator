//! A loop whose trip changes nothing retires at once (RA8EMU-463).
//!
//! RA8EMU-450 skips NOP/B park loops. Idle loops that poll memory, such as
//! ThreadX's __tx_ts_wait (cpsid i; ldr; str; cbnz; cpsie i; b), touch RAM
//! and PRIMASK, so that test refuses them. Here the core watches one trip
//! from a calm loop head (park.calmHead): every instruction still steps and
//! polls as usual, but the data bus goes through a recorder. Back at the head,
//! if the registers, FP state, banked registers, exclusive monitor, event
//! register and active exceptions all equal their values when the trip
//! started, and every store wrote the bytes already there, the next trip
//! starts from the same state and memory, so every one after it is the same.
//! `run` then retires the whole trips that fit, as 450 does.
//!
//! A peripheral read spoils the trip unless the bus says it repeats: a
//! contended IPC semaphore answers the same until the other core releases
//! it, which it can only do at a stretch boundary (RA8EMU-595). Those reads
//! are kept and, on a skip, counted once per retired trip, so the run report
//! reads as if each was made. Any other access outside flash or RAM (a
//! peripheral could answer differently next time), a trip longer than
//! `max_trip`, or a head that stops being calm
//! ends the watch with no skip. A loop that fails waits `backoff` arrivals
//! before it is watched again, so a counting loop costs one slow trip in
//! that many.
//!
//! A trip that only moves R0..R12 and whole RAM words is handed to
//! counted_trip.zig instead (RA8EMU-602): a bounded poll that counts its
//! tries retires the trips its bound allows once two trips moved the same.
const std = @import("std");
const bus = @import("bus.zig");
const memmap = @import("../memmap.zig");
/// Public so park_test reaches park.zig without a root export.
pub const park = @import("park.zig");
const Cpu = @import("cpu.zig").Cpu;
const Regs = @import("regs.zig").Regs;
const FpState = @import("fpu/state.zig").State;
const Banked = @import("../banked.zig").Banked;
const Active = @import("exception/all.zig").active.Active;
const counted = @import("counted_trip.zig");
const td = @import("trip_decode.zig");

pub const max_trip: u32 = 64;
pub const backoff: u16 = 256;
/// Repeatable peripheral reads one trip may make.
pub const max_repeats: usize = 4;

const Repeat = struct { address: u32, len: usize };

/// What one trip may not change.
const Snapshot = struct {
    regs: Regs,
    fp: FpState,
    banked: Banked,
    active: Active,
    exclusive: ?u32,
    event: bool,

    fn take(cpu: *const Cpu) Snapshot {
        return .{ .regs = cpu.regs, .fp = cpu.fp, .banked = cpu.banked, .active = cpu.active, .exclusive = cpu.exclusive, .event = cpu.event };
    }

    /// Field by field: the padding between fields holds no value.
    fn same(self: *const Snapshot, cpu: *const Cpu) bool {
        return bytesEqual(&self.regs, &cpu.regs) and bytesEqual(&self.fp, &cpu.fp) and
            bytesEqual(&self.banked, &cpu.banked) and bytesEqual(&self.active, &cpu.active) and
            self.exclusive == cpu.exclusive and self.event == cpu.event;
    }

    /// Everything but R0..R12 unchanged: what a counted trip may move.
    fn sameButLow(self: *const Snapshot, cpu: *const Cpu) bool {
        var regs = cpu.regs;
        regs.low = self.regs.low;
        return std.meta.eql(self.regs, regs) and bytesEqual(&self.fp, &cpu.fp) and
            bytesEqual(&self.banked, &cpu.banked) and bytesEqual(&self.active, &cpu.active) and
            self.exclusive == cpu.exclusive and self.event == cpu.event;
    }
};

pub const Watch = struct {
    on: bool = false,
    head: u32 = 0,
    steps: u32 = 0,
    /// An access left flash and RAM, or a store no recorder can follow.
    spoiled: bool = false,
    /// A store changed a RAM word this trip.
    changed: bool = false,
    inner: bus.Bus = undefined,
    before: Snapshot = undefined,
    miss_pc: u32 = 0,
    miss_wait: u16 = 0,
    repeated: [max_repeats]Repeat = undefined,
    repeats: usize = 0,
    rec: counted.Recorder = .{},
    /// `run` retired whole trips of a loop that changes nothing and has taken
    /// no exception since, so the core sits parked on it (RA8EMU-1120).
    parked: bool = false,

    /// Called before each instruction `run` executes: instructions to retire
    /// at once from the PC, or 0 to step as usual.
    pub fn observe(self: *Watch, cpu: *Cpu, left: u64) u64 {
        const pc = cpu.regs.pc;
        if (!self.on) {
            self.begin(cpu);
            return 0;
        }
        if (pc != self.head) {
            self.steps += 1;
            if (self.steps > max_trip or self.spoiled) {
                self.miss(cpu);
                return 0;
            }
            self.record(cpu);
            return 0;
        }
        const trip: u64 = self.steps;
        if (self.spoiled or trip == 0 or park.calmHead(cpu) == null) return self.missed(cpu);
        if (!self.changed and self.before.same(cpu)) {
            self.drop(cpu);
            if (left < trip) return 0;
            self.parked = true;
            return self.retire(left / trip) * trip;
        }
        if (!self.before.sameButLow(cpu)) return self.missed(cpu);
        switch (self.rec.atHead(&cpu.regs, self.inner)) {
            .refuse => return self.missed(cpu),
            .again => {
                self.next(cpu);
                return 0;
            },
            .retire => |bound| {
                const trips = @min(bound, left / trip);
                if (trips != 0) self.rec.apply(&cpu.regs, self.inner, trips) catch return self.missed(cpu);
                self.drop(cpu);
                // A bounded poll leaves its loop once the bound runs out.
                self.parked = false;
                return self.retire(trips) * trip;
            },
        }
    }

    /// Counts the trip's repeatable reads once per retired trip.
    fn retire(self: *Watch, trips: u64) u64 {
        if (trips == 0) return 0;
        for (self.repeated[0..self.repeats]) |one| _ = self.inner.repeat(one.address, one.len, trips);
        return trips;
    }

    fn missed(self: *Watch, cpu: *Cpu) u64 {
        self.miss(cpu);
        return 0;
    }

    /// A new trip from the head, for the recorder.
    fn next(self: *Watch, cpu: *Cpu) void {
        self.steps = 1;
        self.changed = false;
        self.repeats = 0;
        self.before = Snapshot.take(cpu);
        self.record(cpu);
    }

    /// The instruction at the PC, as the step about to run fetches it.
    fn record(self: *Watch, cpu: *const Cpu) void {
        const pc = cpu.regs.pc;
        const hw1 = self.inner.readHalf(pc) catch return self.spoil();
        const hw2 = if (td.wide(hw1)) self.inner.readHalf(pc +% 2) catch return self.spoil() else 0;
        self.rec.step(&cpu.regs, hw1, hw2);
    }

    fn spoil(self: *Watch) void {
        self.spoiled = true;
    }

    /// Asked before the read runs, so a free semaphore (which the read
    /// would take) is refused.
    fn note(self: *Watch, address: u32, len: usize) void {
        if (self.repeats == max_repeats or !self.inner.repeat(address, len, 0)) {
            self.spoiled = true;
            return;
        }
        self.repeated[self.repeats] = .{ .address = address, .len = len };
        self.repeats += 1;
    }

    fn begin(self: *Watch, cpu: *Cpu) void {
        const found = park.calmHead(cpu) orelse return;
        if (park.tripLength(found) != null) return; // 450's cheaper path
        if (found.start == self.miss_pc and self.miss_wait != 0) {
            self.miss_wait -= 1;
            return;
        }
        // The head instruction is the trip's first.
        self.* = .{ .on = true, .head = found.start, .steps = 1, .inner = cpu.bus, .before = Snapshot.take(cpu), .miss_pc = self.miss_pc };
        cpu.bus = .{ .ctx = self, .vtable = &vtable, .gate = self.inner.gate, .miss = self.inner.miss, .tally = self.inner.tally };
        self.rec.start(&cpu.regs);
        self.record(cpu);
    }

    fn miss(self: *Watch, cpu: *Cpu) void {
        const head = self.head;
        self.drop(cpu);
        self.miss_pc = head;
        self.miss_wait = backoff;
    }

    /// The interrupt poll reads the SCS for the core, not for the trip, so it
    /// runs on the real bus: its reads are no reason to stop watching.
    pub fn lend(self: *Watch, cpu: *Cpu) bool {
        if (!self.on) return false;
        cpu.bus = self.inner;
        return true;
    }

    /// Back on the recorder after the poll, unless it took an exception: a
    /// trip an exception interrupts is not watched on.
    pub fn reclaim(self: *Watch, cpu: *Cpu, lent: bool, taken: bool) void {
        if (taken) self.parked = false;
        if (!lent) return;
        if (taken) return self.miss(cpu);
        cpu.bus = .{ .ctx = self, .vtable = &vtable, .gate = self.inner.gate, .miss = self.inner.miss, .tally = self.inner.tally };
    }

    /// Put the real bus back. `run` calls this on every way out.
    pub fn drop(self: *Watch, cpu: *Cpu) void {
        if (!self.on) return;
        cpu.bus = self.inner;
        self.on = false;
    }

    const vtable = bus.Bus.VTable{ .read = read, .write = write, .latch = latch };

    /// A fault status bit the core raises mid-trip. Forwarded as a latch, not
    /// a store, so a write-one-to-clear word keeps it (RA8EMU-634); the trip
    /// is spoiled, since a fault is no part of a loop that changes nothing.
    fn latch(ctx: *anyopaque, address: u32, bits: u32) bus.Error!void {
        const self: *Watch = @ptrCast(@alignCast(ctx));
        self.spoiled = true;
        return self.inner.latch(address, bits);
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Watch = @ptrCast(@alignCast(ctx));
        if (!readable(address, into.len)) self.note(address, into.len);
        return self.inner.read(address, into);
    }

    fn write(ctx: *anyopaque, address: u32, bytes: []const u8) bus.Error!void {
        const self: *Watch = @ptrCast(@alignCast(ctx));
        var old: [16]u8 = undefined;
        if (!writable(address, bytes.len) or bytes.len > old.len) {
            self.spoiled = true;
        } else {
            try self.inner.read(address, old[0..bytes.len]);
            if (!std.mem.eql(u8, old[0..bytes.len], bytes)) try self.change(address, bytes.len);
        }
        return self.inner.write(address, bytes);
    }

    /// A store inside one aligned RAM word changes it: the recorder keeps
    /// the word's value before the trip's first change.
    fn change(self: *Watch, address: u32, len: usize) bus.Error!void {
        const aligned = address & ~@as(u32, 3);
        if (address - aligned + len > 4) return self.spoil();
        self.rec.store(aligned, try self.inner.readWord(aligned));
        self.changed = true;
    }
};

fn bytesEqual(a: anytype, b: @TypeOf(a)) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

fn within(address: u32, len: usize, base: u32, end: u32) bool {
    return address >= base and address < end and len <= end - address;
}

/// RAM: what only the core and stretch-boundary agents change.
pub fn writable(address: u32, len: usize) bool {
    const ns = memmap.ns_offset;
    return within(address, len, memmap.dtcm_base, memmap.dtcm_end) or
        within(address, len, memmap.dtcm_base + ns, memmap.dtcm_end + ns) or
        within(address, len, memmap.sram_base, memmap.sram_end) or
        within(address, len, memmap.ns_sram_base, memmap.ns_sram_end);
}

/// RAM and code flash: what a trip may read and see the same next time.
pub fn readable(address: u32, len: usize) bool {
    return writable(address, len) or
        within(address, len, memmap.mram_base, memmap.mram_end) or
        within(address, len, memmap.ns_mram_base, memmap.ns_mram_end);
}
