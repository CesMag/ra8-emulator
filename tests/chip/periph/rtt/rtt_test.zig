//! The drain model against the Zig core's own store: discovery, the checks
//! dev skips, and the ring coming out in order.
const std = @import("std");
const ra8 = @import("ra8");
const Store = ra8.chip.core.cpu.memory.store.Store;
const Guest = ra8.chip.core.cpu.memory.guest.Guest;
const rtt = ra8.chip.periph.rtt;
const block = ra8.chip.periph.rtt.block;

const cb_at: u32 = 0x2200_1000;
const ring_at: u32 = 0x2200_2000;
const ring_size: u32 = 64;

/// A machine with RAM and a control block laid out in it.
const Fixture = struct {
    store: *Store,
    core: Guest,
    model: rtt.Rtt,

    /// The store lives on the heap so the model's handle outlives a move.
    fn open() !Fixture {
        const store = try std.testing.allocator.create(Store);
        errdefer std.testing.allocator.destroy(store);
        store.* = try Store.init(null);
        const core: Guest = .{ .store = store };
        return .{ .store = store, .core = core, .model = .{ .memory = core } };
    }

    fn close(self: *Fixture) void {
        self.store.deinit();
        std.testing.allocator.destroy(self.store);
    }

    /// Write a control block whose up-buffer zero points at `buf`.
    fn plant(self: *Fixture, at: u32, buf: u32, size: u32, count: u32) !void {
        try self.core.write(at, &block.id);
        try self.core.write(at + @as(u32, block.id.len), &@as([6]u8, @splat(0)));
        try self.core.writeWord(at + block.layout.max_up, count);
        try self.core.writeWord(at + block.layout.max_down, 0);
        const up0 = at + block.layout.up0;
        try self.core.writeWord(up0 + block.layout.desc_name, 0);
        try self.core.writeWord(up0 + block.layout.desc_buf, buf);
        try self.core.writeWord(up0 + block.layout.desc_size, size);
        try self.core.writeWord(up0 + block.layout.desc_write, 0);
        try self.core.writeWord(up0 + block.layout.desc_read, 0);
        try self.core.writeWord(up0 + block.layout.desc_flags, 0);
    }

    /// Put `bytes` in the ring and move the write offset the way the firmware
    /// would.
    fn say(self: *Fixture, bytes: []const u8) !void {
        const up0 = cb_at + block.layout.up0;
        const write = try self.core.readWord(up0 + block.layout.desc_write);
        for (bytes, 0..) |byte, index| {
            const at = ring_at + @as(u32, @intCast((write + index) % ring_size));
            try self.core.write(at, &[_]u8{byte});
        }
        const moved: u32 = @intCast((write + bytes.len) % ring_size);
        try self.core.writeWord(up0 + block.layout.desc_write, moved);
    }

    fn readOffset(self: *Fixture) !u32 {
        return self.core.readWord(cb_at + block.layout.up0 + block.layout.desc_read);
    }

    /// Run the model past the first scan.
    fn settle(self: *Fixture) void {
        for (0..rtt.cadence.first_scan) |_| self.model.tick();
    }
};

test "a block is found and its text drained" {
    var fixture = try Fixture.open();
    defer fixture.close();
    try fixture.plant(cb_at, ring_at, ring_size, 1);
    try fixture.say("hello\n");
    fixture.settle();
    try std.testing.expectEqual(@as(?u32, cb_at), fixture.model.found);
    try std.testing.expectEqual(@as(u32, 6), fixture.model.drained);
    try std.testing.expectEqualStrings("hello", fixture.model.line.slice());
}

test "the read offset is stored back so the firmware sees the drain" {
    var fixture = try Fixture.open();
    defer fixture.close();
    try fixture.plant(cb_at, ring_at, ring_size, 1);
    try fixture.say("abc\n");
    fixture.settle();
    try std.testing.expectEqual(@as(u32, 4), try fixture.readOffset());
}

test "text written around the wrap comes out in order" {
    var fixture = try Fixture.open();
    defer fixture.close();
    try fixture.plant(cb_at, ring_at, ring_size, 1);
    try fixture.say(&@as([60]u8, @splat('x')) ++ "\n");
    fixture.settle();
    try fixture.say("wrapped\n");
    fixture.model.tick();
    try std.testing.expectEqualStrings("wrapped", fixture.model.line.slice());
    try std.testing.expectEqual(@as(u32, 2), fixture.model.line.lines);
}

test "the first boundary already scans, so a short run still finds the block" {
    var fixture = try Fixture.open();
    defer fixture.close();
    try fixture.plant(cb_at, ring_at, ring_size, 1);
    try fixture.say("early\n");
    fixture.model.tick();
    try std.testing.expectEqual(@as(u32, 1), fixture.model.scans);
    try std.testing.expectEqualStrings("early", fixture.model.line.slice());
}

test "a fruitless scan backs off instead of scanning every tick" {
    var fixture = try Fixture.open();
    defer fixture.close();
    // Sixty-four boundaries with no RTT anywhere in RAM.
    for (0..64) |_| fixture.model.tick();
    try std.testing.expect(fixture.model.scans <= 8);
    try std.testing.expect(fixture.model.scan_gap > rtt.cadence.first_scan);
}

test "a ring outside RAM is refused, where dev would read the peripheral window" {
    var fixture = try Fixture.open();
    defer fixture.close();
    try fixture.plant(cb_at, 0x4000_0000, ring_size, 1);
    fixture.settle();
    try std.testing.expectEqual(@as(?u32, null), fixture.model.found);
    try std.testing.expectEqual(@as(u32, 1), fixture.model.off_ram);
}

test "a half-built block is skipped and found once it is finished" {
    var fixture = try Fixture.open();
    defer fixture.close();
    try fixture.plant(cb_at, ring_at, 0, 1);
    fixture.settle();
    try std.testing.expectEqual(@as(?u32, null), fixture.model.found);
    try fixture.core.writeWord(cb_at + block.layout.up0 + block.layout.desc_size, ring_size);
    try fixture.say("late\n");
    for (0..64) |_| fixture.model.tick();
    try std.testing.expectEqualStrings("late", fixture.model.line.slice());
}

test "a clobbered block is forgotten and the scan is re-armed, not run every tick" {
    var fixture = try Fixture.open();
    defer fixture.close();
    try fixture.plant(cb_at, ring_at, ring_size, 1);
    fixture.settle();
    const scans = fixture.model.scans;
    try fixture.core.write(cb_at, &@as([block.id.len]u8, @splat(0)));
    fixture.model.tick();
    try std.testing.expectEqual(@as(?u32, null), fixture.model.found);
    try std.testing.expectEqual(@as(u32, 1), fixture.model.forgotten);
    // dev leaves the cadence in the past here and scans every tick for the
    // rest of the run; the backoff is re-armed, so sixty-four boundaries of
    // no block cost a handful of scans.
    for (0..64) |_| fixture.model.tick();
    try std.testing.expect(fixture.model.scans - scans <= 8);
}

test "a torn-down block stops being drained, which dev never notices" {
    var fixture = try Fixture.open();
    defer fixture.close();
    try fixture.plant(cb_at, ring_at, ring_size, 1);
    fixture.settle();
    try fixture.core.writeWord(cb_at + block.layout.max_up, 0);
    try fixture.say("gone\n");
    fixture.model.tick();
    try std.testing.expectEqual(@as(?u32, null), fixture.model.found);
    try std.testing.expectEqual(@as(u32, 0), fixture.model.line.lines);
}

test "a descriptor read mid-update is left for the next tick" {
    var fixture = try Fixture.open();
    defer fixture.close();
    try fixture.plant(cb_at, ring_at, ring_size, 1);
    fixture.settle();
    try fixture.core.writeWord(cb_at + block.layout.up0 + block.layout.desc_write, ring_size + 8);
    fixture.model.tick();
    try std.testing.expectEqual(@as(?u32, cb_at), fixture.model.found);
    try std.testing.expectEqual(@as(u32, 1), fixture.model.skipped);
}

test "an empty ring drains nothing and moves no offset" {
    var fixture = try Fixture.open();
    defer fixture.close();
    try fixture.plant(cb_at, ring_at, ring_size, 1);
    fixture.settle();
    fixture.model.tick();
    try std.testing.expectEqual(@as(u32, 0), fixture.model.drained);
    try std.testing.expectEqual(@as(u32, 0), try fixture.readOffset());
}

test "a block straddling a scan step is still found" {
    var fixture = try Fixture.open();
    defer fixture.close();
    const straddle = 0x2200_0000 + rtt.cadence.step - 4;
    try fixture.plant(straddle, ring_at, ring_size, 1);
    fixture.settle();
    try std.testing.expectEqual(@as(?u32, straddle), fixture.model.found);
}

test "a board with no machine behind it finds nothing" {
    var model = rtt.Rtt{};
    for (0..64) |_| model.tick();
    try std.testing.expectEqual(@as(u32, 0), model.ticks);
    try std.testing.expect(model.quiet());
}

test "a run that drained text is not quiet" {
    var fixture = try Fixture.open();
    defer fixture.close();
    try std.testing.expect(fixture.model.quiet());
    try fixture.plant(cb_at, ring_at, ring_size, 1);
    try fixture.say("up\n");
    fixture.settle();
    try std.testing.expect(!fixture.model.quiet());
}
