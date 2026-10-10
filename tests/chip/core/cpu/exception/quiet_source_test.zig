//! Covers src/chip/core/cpu/exception/quiet_source.zig.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("ram.zig");
const Fake = @import("fake_source.zig").Fake;
const QuietSource = ra8.chip.core.cpu.exception.quiet_source.QuietSource;
const Key = ra8.chip.core.cpu.exception.quiet_source.Key;
const bus = ra8.chip.core.cpu.bus;

const systick: ra8.chip.core.cpu.exception.active.Entry = .{ .number = 15, .priority = 0x80 };

const LatchProbe = struct {
    writes: u32 = 0,
    latches: u32 = 0,
    value: u32 = 0,

    fn view(self: *LatchProbe) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write, .latch = latch } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        _ = address;
        const self: *LatchProbe = @ptrCast(@alignCast(ctx));
        var word: [4]u8 = undefined;
        std.mem.writeInt(u32, &word, self.value, .little);
        @memcpy(into, word[0..into.len]);
    }

    fn write(ctx: *anyopaque, address: u32, bytes: []const u8) bus.Error!void {
        _ = address;
        const self: *LatchProbe = @ptrCast(@alignCast(ctx));
        self.writes += 1;
        var word: [4]u8 = @splat(0);
        @memcpy(word[0..bytes.len], bytes);
        self.value = std.mem.readInt(u32, &word, .little);
    }

    fn latch(ctx: *anyopaque, address: u32, bits: u32) bus.Error!void {
        _ = address;
        const self: *LatchProbe = @ptrCast(@alignCast(ctx));
        self.latches += 1;
        self.value |= bits;
    }
};

fn settled(ram: *fixture.Ram, fake: *Fake) QuietSource {
    fake.pending = null;
    return .{ .inner = fake.source(), .memory = ram.view() };
}

test "a nothing-pending answer stands until something stirs" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{};
    var quiet = settled(&ram, &fake);
    const source = quiet.source();
    try std.testing.expect((try source.winner(quiet.bus())) == null);
    fake.pending = systick;
    try std.testing.expect((try source.winner(quiet.bus())) == null);
    quiet.stir();
    try std.testing.expectEqual(@as(u9, 15), (try source.winner(quiet.bus())).?.number);
}

test "a pending answer is never held" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{ .pending = systick };
    var quiet: QuietSource = .{ .inner = fake.source(), .memory = ram.view() };
    const source = quiet.source();
    try std.testing.expect((try source.winner(quiet.bus())) != null);
    fake.pending = null;
    try std.testing.expect((try source.winner(quiet.bus())) == null);
}

test "RAM traffic leaves it settled, a system-space store stirs it" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{};
    var quiet = settled(&ram, &fake);
    const source = quiet.source();
    const memory = quiet.bus();
    _ = try source.winner(memory);
    fake.pending = systick;
    try memory.write(fixture.base + 0x200, &.{ 1, 2, 3, 4 });
    _ = try memory.readWord(fixture.base + 0x200);
    try std.testing.expect((try source.winner(memory)) == null);
    _ = try memory.readWord(fixture.scs + 0xD04);
    try std.testing.expect((try source.winner(memory)) == null);
    try memory.write(fixture.scs + 0x200, &.{ 0, 0, 0, 0 });
    try std.testing.expect((try source.winner(memory)) != null);
}

test "a peripheral read stirs it, an SCB read does not (RA8EMU-418)" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{};
    var quiet = settled(&ram, &fake);
    const source = quiet.source();
    const memory = quiet.bus();
    _ = try source.winner(memory);
    fake.pending = systick;
    _ = try memory.readWord(fixture.scs + 0xD0C);
    _ = try memory.readWord(fixture.scs + 0xD24);
    try std.testing.expect((try source.winner(memory)) == null);
    try std.testing.expectError(bus.Error.Unmapped, memory.readWord(0x4000_0000));
    try std.testing.expect((try source.winner(memory)) != null);
}

test "the bus it hands out reaches the run's memory" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{};
    var quiet = settled(&ram, &fake);
    try quiet.bus().write(fixture.scs + 0xD04, &.{ 0, 0, 0, 0x10 });
    try std.testing.expectEqual(@as(u32, 0x1000_0000), ram.word(fixture.scs + 0xD04));
    try std.testing.expectEqual(@as(u32, 0x1000_0000), try quiet.bus().readWord(fixture.scs + 0xD04));
}

test "the bus it hands out preserves the direct-memory view" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{};
    var quiet = settled(&ram, &fake);
    var flash = [_]u8{ 1, 2, 3, 4 };
    var direct: bus.DirectMemory = .{ .flash = &flash, .enabled = true };
    quiet.memory.direct = &direct;

    try std.testing.expect(quiet.bus().direct == &direct);
    try std.testing.expectEqual(@as(u32, 0x0403_0201), try quiet.bus().readWord(ra8.chip.core.memmap.mram_base));
}

test "taking or leaving an exception stirs and forwards" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{};
    var quiet = settled(&ram, &fake);
    const source = quiet.source();
    _ = try source.winner(ram.view());
    try source.taken(ram.view(), 15);
    try std.testing.expect(!quiet.settled);
    _ = try source.winner(ram.view());
    try source.returned(ram.view(), 15);
    try std.testing.expect(!quiet.settled);
    try std.testing.expectEqual(@as(u32, 1), fake.taken);
    try std.testing.expectEqual(@as(?u9, 15), fake.last_returned);
}

test "each run of the core starts by stirring" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{};
    var quiet = settled(&ram, &fake);
    var cpu = try fixture.boot(&ram);
    ram.putHalf(fixture.code, 0xBF00);
    cpu.quiet = &quiet;
    quiet.settled = true;
    _ = cpu.run(0);
    try std.testing.expect(!quiet.settled);
}

const unmasked: Key = .{ .primask = 0, .basepri = 0, .faultmask = 0, .depth = 0, .running = 0xFFFF };

test "hush only takes once answered, and a stir lifts it (RA8EMU-429)" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{};
    var quiet: QuietSource = .{ .inner = fake.source(), .memory = ram.view() };
    quiet.hush(unmasked, true);
    try std.testing.expect(!quiet.holds(unmasked));
    _ = try quiet.source().winner(quiet.bus());
    quiet.hush(unmasked, true);
    try std.testing.expect(quiet.holds(unmasked));
    var masked = unmasked;
    masked.primask = 1;
    try std.testing.expect(quiet.holds(masked));
    try quiet.bus().write(fixture.scs + 0x200, &.{ 0, 0, 0, 0 });
    try std.testing.expect(!quiet.holds(unmasked));
    _ = try quiet.source().winner(quiet.bus());
    quiet.hush(unmasked, true);
    quiet.stir();
    try std.testing.expect(!quiet.holds(unmasked));
}

test "a masked pend hushes for its key only (RA8EMU-437)" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{ .pending = systick };
    var quiet: QuietSource = .{ .inner = fake.source(), .memory = ram.view() };
    var masked = unmasked;
    masked.primask = 1;
    try std.testing.expect((try quiet.source().winner(quiet.bus())) != null);
    quiet.hush(masked, false);
    try std.testing.expect(quiet.holds(masked));
    try std.testing.expect(!quiet.holds(unmasked));
    var deeper = masked;
    deeper.depth = 1;
    deeper.running = 3;
    try std.testing.expect(!quiet.holds(deeper));
    _ = try quiet.bus().readWord(fixture.scs + 0xD0C);
    try std.testing.expect(quiet.holds(masked));
    quiet.stir();
    try std.testing.expect(!quiet.holds(masked));
}

test "the wrapped bus preserves status latches" {
    var probe: LatchProbe = .{};
    var fake: Fake = .{};
    var quiet: QuietSource = .{ .inner = fake.source(), .memory = probe.view() };
    try quiet.bus().latch(ra8.chip.core.memmap.scb.cfsr, 1 << 25);
    try std.testing.expectEqual(@as(u32, 1), probe.latches);
    try std.testing.expectEqual(@as(u32, 0), probe.writes);
    try std.testing.expectEqual(@as(u32, 1 << 25), probe.value);
}

const RepeatProbe = struct {
    allow: bool = true,
    times: u64 = 0,

    fn view(self: *RepeatProbe) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write, .repeat = repeat } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        _ = ctx;
        _ = address;
        @memset(into, 0);
    }

    fn write(ctx: *anyopaque, address: u32, bytes: []const u8) bus.Error!void {
        _ = ctx;
        _ = address;
        _ = bytes;
    }

    fn repeat(ctx: *anyopaque, address: u32, len: usize, times: u64) bool {
        _ = address;
        _ = len;
        const self: *RepeatProbe = @ptrCast(@alignCast(ctx));
        self.times += times;
        return self.allow;
    }
};

test "a repeat passes through to the real bus and stirs only when it reads" {
    var fake: Fake = .{};
    var probe: RepeatProbe = .{};
    var quiet: QuietSource = .{ .inner = fake.source(), .memory = probe.view() };
    const source = quiet.source();
    try std.testing.expect((try source.winner(quiet.bus())) == null);
    try std.testing.expect(quiet.bus().repeat(0x5002_00C0, 4, 0));
    try std.testing.expect(quiet.settled);
    try std.testing.expect(quiet.bus().repeat(0x5002_00C0, 4, 7));
    try std.testing.expectEqual(@as(u64, 7), probe.times);
    try std.testing.expect(!quiet.settled);
    probe.allow = false;
    try std.testing.expect(!quiet.bus().repeat(0x5002_00C0, 4, 3));
}
