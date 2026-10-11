//! Covers src/chip/core/cpu/fixed_trip.zig: a loop whose trip changes nothing
//! retires at once (RA8EMU-463).
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("exception/ram.zig");
const Fake = @import("exception/fake_source.zig").Fake;
const QuietSource = ra8.chip.core.cpu.exception.quiet_source.QuietSource;
const BlockCache = ra8.chip.core.cpu.decode.block_cache.BlockCache;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const memmap = ra8.chip.core.memmap;
const bus_fault = ra8.chip.periph.fault.status.bus;
const status = ra8.chip.periph.fault.status;
const Stop = ra8.chip.core.cpu.cpu.Stop;
const fixed_trip = ra8.chip.core.cpu.cpu.fixed_trip;

/// A core on the fixture RAM polling through a settled quiet source, with
/// formed blocks, as park_test.zig builds it.
const Rig = struct {
    ram: fixture.Ram = .{},
    fake: Fake = .{},
    quiet: QuietSource = undefined,
    cache: *BlockCache = undefined,
    cpu: Cpu = undefined,

    fn init(self: *Rig, code: []const u16) !void {
        for (code, 0..) |half, i| self.ram.putHalf(fixture.code + @as(u32, @intCast(2 * i)), half);
        self.cpu = try fixture.boot(&self.ram);
        self.quiet = .{ .inner = self.fake.source(), .memory = self.ram.view() };
        self.cache = try std.testing.allocator.create(BlockCache);
        self.cache.init();
        self.cpu.bus = self.quiet.bus();
        self.cpu.source = self.quiet.source();
        self.cpu.quiet = &self.quiet;
        self.cpu.blocks = self.cache;
        aim(&self.cpu);
    }

    fn deinit(self: *Rig) void {
        std.testing.allocator.destroy(self.cache);
    }
};

const flag: u32 = fixture.base + 0x200;
const copy: u32 = fixture.base + 0x204;

fn aim(cpu: *Cpu) void {
    cpu.regs.set(0, copy);
    cpu.regs.set(1, 0);
    cpu.regs.set(2, flag);
}

/// The same code stepped one instruction at a time, with no shortcut.
fn plain(ram: *fixture.Ram, code: []const u16, count: u64) !Cpu {
    for (code, 0..) |half, i| ram.putHalf(fixture.code + @as(u32, @intCast(2 * i)), half);
    var cpu = try fixture.boot(ram);
    aim(&cpu);
    try std.testing.expectEqual(Stop.count, cpu.run(count));
    return cpu;
}

// ThreadX's __tx_ts_wait, from arm-none-eabi-as 13.3:
// head: cpsid i; ldr r1, [r2]; str r1, [r0]; cbnz r1, ready; cpsie i;
// b head; ready: b ready.
const ts_wait = [_]u16{ 0xB672, 0x6811, 0x6001, 0xB909, 0xB662, 0xE7F9, 0xE7FE };
// adds r3, #1; b back.
const count_loop = [_]u16{ 0x3301, 0xE7FD };
// adds r3, #1; str r3, [r0]; b back.
const store_loop = [_]u16{ 0x3301, 0x6003, 0xE7FC };

test "an idle __tx_ts_wait retires whole trips at once and ends where stepping would" {
    var rig: Rig = .{};
    try rig.init(&ts_wait);
    defer rig.deinit();
    try std.testing.expectEqual(Stop.count, rig.cpu.run(1003));
    var ram: fixture.Ram = .{};
    const stepped = try plain(&ram, &ts_wait, 1003);
    try std.testing.expectEqual(stepped.retired, rig.cpu.retired);
    try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&stepped.regs), std.mem.asBytes(&rig.cpu.regs)));
    // Stepped, the loop would start its two blocks about 330 times.
    try std.testing.expect(rig.cache.reused < 16);
}

test "the real bus is back once run returns" {
    var rig: Rig = .{};
    try rig.init(&ts_wait);
    defer rig.deinit();
    const before = rig.cpu.bus;
    _ = rig.cpu.run(3);
    try std.testing.expectEqual(before.ctx, rig.cpu.bus.ctx);
    try std.testing.expectEqual(before.vtable, rig.cpu.bus.vtable);
    try std.testing.expect(!rig.cpu.trip.on);
}

test "a ready flag ends the wait on the next trip" {
    var rig: Rig = .{};
    try rig.init(&ts_wait);
    defer rig.deinit();
    rig.ram.putWord(flag, 7);
    try std.testing.expectEqual(Stop.count, rig.cpu.run(20));
    try std.testing.expectEqual(fixture.code + 12, rig.cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 7), rig.ram.word(copy));
}

test "a trip that changes a register is stepped" {
    var rig: Rig = .{};
    try rig.init(&count_loop);
    defer rig.deinit();
    try std.testing.expectEqual(Stop.count, rig.cpu.run(1000));
    try std.testing.expectEqual(@as(u64, 1000), rig.cpu.retired);
    try std.testing.expectEqual(@as(u32, 500), rig.cpu.regs.get(3));
}

test "a trip that stores a new value is stepped" {
    var rig: Rig = .{};
    try rig.init(&store_loop);
    defer rig.deinit();
    try std.testing.expectEqual(Stop.count, rig.cpu.run(999));
    try std.testing.expectEqual(@as(u32, 333), rig.cpu.regs.get(3));
    try std.testing.expectEqual(@as(u32, 333), rig.ram.word(copy));
}

test "a pending interrupt is still taken" {
    var rig: Rig = .{};
    try rig.init(&ts_wait);
    defer rig.deinit();
    _ = rig.cpu.run(50);
    rig.fake.pending = .{ .number = 11, .priority = 0 };
    rig.quiet.stir();
    _ = rig.cpu.run(100);
    try std.testing.expectEqual(@as(u32, 1), rig.fake.taken);
}

test "only RAM is writable, flash is readable too, and address zero is neither" {
    try std.testing.expect(fixed_trip.writable(0x2000_0000, 4));
    try std.testing.expect(fixed_trip.writable(0x2200_0010, 4));
    try std.testing.expect(!fixed_trip.writable(0x2000_FFFE, 4));
    try std.testing.expect(!fixed_trip.writable(0x0200_0000, 4));
    try std.testing.expect(fixed_trip.readable(0x0200_0000, 4));
    try std.testing.expect(!fixed_trip.readable(0x0000_0100, 2));
    try std.testing.expect(!fixed_trip.readable(0x4000_0000, 4));
    try std.testing.expect(!fixed_trip.readable(0xE000_E010, 4));
}

/// A peripheral word that reads zero and counts every read: a semaphore
/// held by the other core. `repeats` says whether its bus offers RA8EMU-595's
/// repeat; without it every trip is stepped.
const Held = struct {
    inner: ra8.chip.core.cpu.bus.Bus,
    reads: u64 = 0,

    const at: u32 = 0x4040_0000;
    const with = ra8.chip.core.cpu.bus.Bus.VTable{ .read = read, .write = write, .repeat = repeat };
    const without = ra8.chip.core.cpu.bus.Bus.VTable{ .read = read, .write = write };

    fn view(self: *Held, repeats: bool) ra8.chip.core.cpu.bus.Bus {
        return .{ .ctx = self, .vtable = if (repeats) &with else &without };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) ra8.chip.core.cpu.bus.Error!void {
        const self: *Held = @ptrCast(@alignCast(ctx));
        if (address != at) return self.inner.read(address, into);
        self.reads += 1;
        @memset(into, 0);
    }

    fn write(ctx: *anyopaque, address: u32, bytes: []const u8) ra8.chip.core.cpu.bus.Error!void {
        const self: *Held = @ptrCast(@alignCast(ctx));
        return self.inner.write(address, bytes);
    }

    fn repeat(ctx: *anyopaque, address: u32, len: usize, times: u64) bool {
        const self: *Held = @ptrCast(@alignCast(ctx));
        _ = len;
        if (address != at) return false;
        self.reads += times;
        return true;
    }
};

const Spun = struct { retired: u64, reads: u64, reused: u64, pc: u32 };

fn spin(repeats: bool) !Spun {
    var rig: Rig = .{};
    try rig.init(&ts_wait);
    defer rig.deinit();
    var held: Held = .{ .inner = rig.cpu.bus };
    rig.cpu.bus = held.view(repeats);
    rig.cpu.regs.set(2, Held.at);
    try std.testing.expectEqual(Stop.count, rig.cpu.run(1003));
    return .{ .retired = rig.cpu.retired, .reads = held.reads, .reused = rig.cache.reused, .pc = rig.cpu.regs.pc };
}

test "a spin on a repeatable peripheral read retires at once and counts every read" {
    const skipped = try spin(true);
    const stepped = try spin(false);
    try std.testing.expectEqual(stepped.retired, skipped.retired);
    try std.testing.expectEqual(stepped.reads, skipped.reads);
    try std.testing.expectEqual(stepped.pc, skipped.pc);
    try std.testing.expect(stepped.reads > 100);
    try std.testing.expect(skipped.reused < 16);
}

test "a peripheral read the bus cannot repeat still spoils the trip" {
    const stepped = try spin(false);
    try std.testing.expect(stepped.reused > 100);
}

// head: adds r3, #1; cmp r3, r4; bls head; done: b done. A bounded count.
const bounded_loop = [_]u16{ 0x3301, 0x42A3, 0xD9FC, 0xE7FE };
// head: ldr r3, [r0]; adds r3, #1; str r3, [r0]; cmp r3, r4; bls head;
// done: b done. The count kept in a RAM word, as internal_ns_ipc_recv does.
const word_loop = [_]u16{ 0x6803, 0x3301, 0x6003, 0x42A3, 0xD9FA, 0xE7FE };

const Counted = struct { retired: u64, pc: u32, r3: u32, word: u32, reused: u64 };

fn counting(code: []const u16, limit: u32, budget: u64, shortcut: bool) !Counted {
    var rig: Rig = .{};
    try rig.init(code);
    defer rig.deinit();
    if (!shortcut) {
        rig.cpu.quiet = null;
        rig.cpu.blocks = null;
    }
    rig.cpu.regs.set(4, limit);
    try std.testing.expectEqual(Stop.count, rig.cpu.run(budget));
    return .{ .retired = rig.cpu.retired, .pc = rig.cpu.regs.pc, .r3 = rig.cpu.regs.get(3), .word = rig.ram.word(copy), .reused = rig.cache.reused };
}

test "a bounded count retires the trips before its bound and ends where stepping would" {
    for ([_]u32{ 7, 3000 }) |limit| {
        for ([_]u64{ 50, 9001 }) |budget| {
            const fast = try counting(&bounded_loop, limit, budget, true);
            const slow = try counting(&bounded_loop, limit, budget, false);
            try std.testing.expectEqual(slow.retired, fast.retired);
            try std.testing.expectEqual(slow.pc, fast.pc);
            try std.testing.expectEqual(slow.r3, fast.r3);
        }
    }
    // Stepped, 3000 trips would start the loop's block about 3000 times.
    try std.testing.expect((try counting(&bounded_loop, 3000, 9001, true)).reused < 64);
}

test "a count kept in a RAM word moves on with the word" {
    for ([_]u64{ 60, 12_001 }) |budget| {
        const fast = try counting(&word_loop, 2500, budget, true);
        const slow = try counting(&word_loop, 2500, budget, false);
        try std.testing.expectEqual(slow.retired, fast.retired);
        try std.testing.expectEqual(slow.pc, fast.pc);
        try std.testing.expectEqual(slow.r3, fast.r3);
        try std.testing.expectEqual(slow.word, fast.word);
    }
    try std.testing.expect((try counting(&word_loop, 2500, 12_001, true)).reused < 64);
}

test "the poll borrows the real bus only from a watch that is on" {
    var rig: Rig = .{};
    try rig.init(&bounded_loop);
    defer rig.deinit();
    const before = rig.cpu.bus;
    try std.testing.expect(!rig.cpu.trip.lend(&rig.cpu));
    rig.cpu.trip.reclaim(&rig.cpu, false, true);
    try std.testing.expectEqual(before.ctx, rig.cpu.bus.ctx);
    try std.testing.expect(!rig.cpu.trip.on);
}

test "a fault latched mid-trip reaches the bus as a latch and spoils the trip" {
    var under = @import("latch_bus.zig").Latches{};
    var cpu: Cpu = .{ .bus = under.view() };
    var watch = fixed_trip.Watch{ .on = true, .inner = under.view() };
    watch.reclaim(&cpu, true, false);
    try cpu.bus.latch(0xE000_ED28, 1 << 25);
    try std.testing.expectEqual(@as(u32, 1 << 25), under.latched);
    try std.testing.expectEqual(@as(u32, 0), under.writes);
    try std.testing.expect(watch.spoiled);
}

test "a refused post-indexed load through the trip bus takes a precise BusFault" {
    var rig: Rig = .{};
    try rig.init(&.{ 0xF852, 0x1B04, 0xBF00 });
    defer rig.deinit();

    const bus_handler = fixture.base + 0x1E0;
    rig.ram.putWord(fixture.base + 3 * 4, (fixture.base + 0x1C0) | 1);
    rig.ram.putWord(fixture.base + 5 * 4, bus_handler | 1);
    rig.ram.putWord(memmap.scb.shcsr, 1 << 17);
    var miss: u32 = 0xFFFF_FFFF;
    var tally: bus_fault.Tally = .{};
    rig.cpu.bus.miss = &miss;
    rig.cpu.bus.tally = &tally;
    rig.cpu.regs.set(1, 0xCAFE_F00D);
    rig.cpu.regs.set(2, fixture.base + 0x200);

    _ = rig.cache.next(rig.cpu.bus, rig.cpu.profile, fixture.code);
    rig.quiet.settled = true;
    try std.testing.expectEqual(@as(u64, 0), rig.cpu.trip.observe(&rig.cpu, 1));
    try std.testing.expect(rig.cpu.trip.on);
    rig.cpu.regs.set(2, 0);
    try std.testing.expectEqual(@as(?Stop, null), rig.cpu.step());

    try std.testing.expectEqual(bus_handler, rig.cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 5), rig.cpu.regs.xpsr & 0x1FF);
    try std.testing.expectEqual(status.Cause.preciserr.bit() | status.Cause.bfarvalid.bit(), rig.ram.word(memmap.scb.cfsr));
    try std.testing.expectEqual(@as(u32, 0), rig.ram.word(memmap.scb.bfar));
    try std.testing.expectEqual(fixture.code, rig.ram.word(fixture.msp_top - 8));
    try std.testing.expectEqual(@as(u32, 0xCAFE_F00D), rig.cpu.regs.get(1));
    try std.testing.expectEqual(@as(u32, 0), rig.cpu.regs.get(2));
    try std.testing.expectEqual(bus_fault.Tally{ .raised = 1 }, tally);
}
