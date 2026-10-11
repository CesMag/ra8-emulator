//! Covers src/chip/core/cpu/park.zig: a park loop retires at once (RA8EMU-450).
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("exception/ram.zig");
const Fake = @import("exception/fake_source.zig").Fake;
const QuietSource = ra8.chip.core.cpu.exception.quiet_source.QuietSource;
const BlockCache = ra8.chip.core.cpu.decode.block_cache.BlockCache;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const RetireListener = ra8.chip.core.cpu.cpu.RetireListener;

/// A core on the fixture RAM polling through a settled quiet source, with
/// formed blocks.
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
    }

    fn deinit(self: *Rig) void {
        std.testing.allocator.destroy(self.cache);
    }
};

/// The same code stepped one instruction at a time, with no shortcut.
fn plain(code: []const u16, count: u64) !Cpu {
    var ram: fixture.Ram = .{};
    for (code, 0..) |half, i| ram.putHalf(fixture.code + @as(u32, @intCast(2 * i)), half);
    var cpu = try fixture.boot(&ram);
    try std.testing.expectEqual(ra8.chip.core.cpu.cpu.Stop.count, cpu.run(count));
    return cpu;
}

// NOP; B back to the NOP.
const park_loop = [_]u16{ 0xBF00, 0xE7FD };
// STR r0, [r1]; B back to the STR.
const store_loop = [_]u16{ 0x6008, 0xE7FD };

test "a park loop retires whole trips at once and ends where stepping would" {
    var rig: Rig = .{};
    try rig.init(&park_loop);
    defer rig.deinit();
    try std.testing.expectEqual(ra8.chip.core.cpu.cpu.Stop.count, rig.cpu.run(1001));
    const stepped = try plain(&park_loop, 1001);
    try std.testing.expectEqual(stepped.retired, rig.cpu.retired);
    try std.testing.expectEqual(stepped.regs.pc, rig.cpu.regs.pc);
    // Stepped, the loop would start its block about 500 times.
    try std.testing.expect(rig.cache.reused < 8);
}

test "a b-to-itself loop is a park loop of one" {
    var rig: Rig = .{};
    try rig.init(&.{0xE7FE});
    defer rig.deinit();
    try std.testing.expectEqual(ra8.chip.core.cpu.cpu.Stop.count, rig.cpu.run(777));
    try std.testing.expectEqual(@as(u64, 777), rig.cpu.retired);
    try std.testing.expectEqual(fixture.code, rig.cpu.regs.pc);
    try std.testing.expect(rig.cache.reused < 8);
}

test "a loop that stores is not a park loop" {
    var rig: Rig = .{};
    try rig.init(&store_loop);
    defer rig.deinit();
    rig.cpu.regs.set(1, fixture.base + 0x200);
    const found = ra8.chip.core.cpu.cpu.fixed_trip.park.calmHead(&rig.cpu);
    try std.testing.expect(found == null or ra8.chip.core.cpu.cpu.fixed_trip.park.tripLength(found.?) == null);
    // RA8EMU-463 may still retire it once a trip stores the value already
    // there; the count and the PC come out as stepping leaves them.
    try std.testing.expectEqual(ra8.chip.core.cpu.cpu.Stop.count, rig.cpu.run(1000));
    try std.testing.expectEqual(@as(u64, 1000), rig.cpu.retired);
    try std.testing.expectEqual(fixture.code, rig.cpu.regs.pc);
}

const Counter = struct {
    seen: u64 = 0,
    fn listener(self: *Counter) RetireListener {
        return .{ .context = self, .instructionFn = hear };
    }
    fn hear(context: *anyopaque, _: u32) void {
        const self: *Counter = @ptrCast(@alignCast(context));
        self.seen += 1;
    }
};

test "a retire listener hears every trip" {
    var rig: Rig = .{};
    try rig.init(&park_loop);
    defer rig.deinit();
    var counter: Counter = .{};
    rig.cpu.retire_listener = counter.listener();
    try std.testing.expectEqual(ra8.chip.core.cpu.cpu.Stop.count, rig.cpu.run(1000));
    try std.testing.expectEqual(@as(u64, 1000), counter.seen);
}

test "a pending interrupt is never skipped past" {
    var rig: Rig = .{};
    try rig.init(&park_loop);
    defer rig.deinit();
    _ = rig.cpu.run(10);
    rig.fake.pending = .{ .number = 11, .priority = 0 };
    rig.quiet.stir();
    _ = rig.cpu.run(100);
    try std.testing.expectEqual(@as(u32, 1), rig.fake.taken);
}

test "a park loop's skip notes the core parked (RA8EMU-1120)" {
    var rig: Rig = .{};
    try rig.init(&park_loop);
    defer rig.deinit();
    _ = rig.cpu.run(1001);
    try std.testing.expect(rig.cpu.trip.parked);
}

test "a run that retires no whole trips clears the park note" {
    var rig: Rig = .{};
    try rig.init(&park_loop);
    defer rig.deinit();
    _ = rig.cpu.run(1001);
    var counter: Counter = .{};
    rig.cpu.retire_listener = counter.listener();
    _ = rig.cpu.run(10);
    try std.testing.expect(!rig.cpu.trip.parked);
}

test "a taken exception clears the park note" {
    var rig: Rig = .{};
    try rig.init(&park_loop);
    defer rig.deinit();
    _ = rig.cpu.run(1001);
    rig.cpu.trip.reclaim(&rig.cpu, false, true);
    try std.testing.expect(!rig.cpu.trip.parked);
}
