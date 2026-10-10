//! The descriptor engine against a real machine: a frame out, a frame in,
//! and the rings the model refuses to walk.
const std = @import("std");
const ra8 = @import("ra8");
const Store = ra8.chip.core.cpu.memory.store.Store;
const Guest = ra8.chip.core.cpu.memory.guest.Guest;
const desc = ra8.chip.periph.eth.desc;
const eth_dma = ra8.chip.periph.eth.dma;
const eth_peer = ra8.components.eth_peer;

const linkfix_at: u32 = 0x2200_1000;
const chain_at: u32 = 0x2200_1100;
const buffer_at: u32 = 0x2200_2000;

/// A machine with RAM, and a descriptor engine pointed at a LINKFIX table in
/// it, wired to a far end. The store and the far end live on the heap so the
/// rings' handles outlive a move.
const Fixture = struct {
    store: *Store,
    core: Guest,
    far: *eth_peer.Link,
    rings: eth_dma.Dma,

    fn open() !Fixture {
        const store = try std.testing.allocator.create(Store);
        errdefer std.testing.allocator.destroy(store);
        store.* = try Store.init(null);
        errdefer store.deinit();
        const far = try std.testing.allocator.create(eth_peer.Link);
        far.* = .{};
        const core: Guest = .{ .store = store };
        const rings: eth_dma.Dma = .{ .memory = core, .linkfix = linkfix_at, .link = far.wire() };
        return .{ .store = store, .core = core, .far = far, .rings = rings };
    }

    fn close(self: *Fixture) void {
        self.store.deinit();
        std.testing.allocator.destroy(self.store);
        std.testing.allocator.destroy(self.far);
    }

    /// Write an eight-byte descriptor at `at`.
    fn plant(self: *Fixture, at: u32, dt: desc.Dt, ds: u32, ptr: u32) !void {
        const size = desc.dsBytes(0, ds);
        var raw = @as([desc.size]u8, @splat(0));
        raw[desc.layout.ds_low] = size[0];
        raw[desc.layout.ds_high] = size[1];
        raw[desc.layout.dt] = desc.dtByte(0, dt);
        std.mem.writeInt(u32, raw[desc.layout.ptr..][0..4], ptr, .little);
        try self.core.write(at, &raw);
    }

    /// Point queue `queue`'s LINKFIX entry at `chain`.
    fn point(self: *Fixture, queue: u32, chain: u32) !void {
        try self.plant(linkfix_at + queue * desc.size, .linkfix, 0, chain);
    }

    fn typeAt(self: *Fixture, at: u32) !desc.Dt {
        var raw: [desc.size]u8 = undefined;
        try self.core.read(at, &raw);
        return desc.Desc.decode(raw).dt;
    }

    fn sizeAt(self: *Fixture, at: u32) !u32 {
        var raw: [desc.size]u8 = undefined;
        try self.core.read(at, &raw);
        return desc.Desc.decode(raw).ds;
    }
};

const frame = @as([64]u8, @splat(0xA5));

test "a kicked queue moves its frame and frees the slot" {
    var fix = try Fixture.open();
    defer fix.close();
    try fix.point(0, chain_at);
    try fix.plant(chain_at, .fsingle, frame.len, buffer_at);
    try fix.core.write(buffer_at, &frame);

    fix.rings.kick(1, 0, true);

    try std.testing.expectEqual(@as(u32, 1), fix.rings.tx_frames);
    try std.testing.expectEqualSlices(u8, &frame, fix.far.sent.peek().?);
    try std.testing.expectEqual(desc.Dt.fempty, try fix.typeAt(chain_at));
}

test "a kick on a gateway that is not running moves nothing" {
    var fix = try Fixture.open();
    defer fix.close();
    try fix.point(0, chain_at);
    try fix.plant(chain_at, .fsingle, frame.len, buffer_at);

    fix.rings.kick(1, 0, false);

    try std.testing.expectEqual(@as(u32, 0), fix.rings.tx_frames);
    try std.testing.expectEqual(@as(u32, 1), fix.rings.refused.stopped);
    try std.testing.expectEqual(desc.Dt.fsingle, try fix.typeAt(chain_at));
}

test "a far end with no room leaves the descriptor owned by the gateway" {
    var fix = try Fixture.open();
    defer fix.close();
    try fix.point(0, chain_at);
    try fix.plant(chain_at, .fsingle, frame.len, buffer_at);
    var n: usize = 0;
    while (n < eth_peer.depth) : (n += 1) _ = fix.far.send(&frame);

    fix.rings.kick(1, 0, true);

    try std.testing.expectEqual(@as(u32, 0), fix.rings.tx_frames);
    try std.testing.expectEqual(@as(u32, 1), fix.rings.refused.blocked);
    try std.testing.expectEqual(desc.Dt.fsingle, try fix.typeAt(chain_at));
}

test "a buffer outside RAM is not marshalled" {
    var fix = try Fixture.open();
    defer fix.close();
    try fix.point(0, chain_at);
    try fix.plant(chain_at, .fsingle, frame.len, 0x4000_0000);

    fix.rings.kick(1, 0, true);

    try std.testing.expectEqual(@as(u32, 1), fix.rings.refused.off_ram);
    try std.testing.expectEqual(@as(u32, 0), fix.rings.tx_frames);
}

test "a descriptor too short to be a frame is refused" {
    var fix = try Fixture.open();
    defer fix.close();
    try fix.point(0, chain_at);
    try fix.plant(chain_at, .fsingle, 4, buffer_at);

    fix.rings.kick(1, 0, true);

    try std.testing.expectEqual(@as(u32, 1), fix.rings.refused.runt);
}

test "a multi-fragment head is left alone, not completed" {
    var fix = try Fixture.open();
    defer fix.close();
    try fix.point(0, chain_at);
    try fix.plant(chain_at, .fstart, frame.len, buffer_at);

    fix.rings.kick(1, 0, true);

    try std.testing.expectEqual(@as(u32, 1), fix.rings.refused.fragment);
    try std.testing.expectEqual(desc.Dt.fstart, try fix.typeAt(chain_at));
}

test "every queue in the request word is kicked" {
    var fix = try Fixture.open();
    defer fix.close();
    try fix.point(0, chain_at);
    try fix.point(3, chain_at + desc.size);
    try fix.plant(chain_at, .fsingle, frame.len, buffer_at);
    try fix.plant(chain_at + desc.size, .fsingle, frame.len, buffer_at);

    fix.rings.kick(0b1001, 0, true);

    try std.testing.expectEqual(@as(u32, 2), fix.rings.tx_frames);
}

test "a queue with no chain head moves nothing" {
    var fix = try Fixture.open();
    defer fix.close();
    try fix.point(0, 0);

    fix.rings.kick(1, 0, true);

    try std.testing.expectEqual(@as(u32, 1), fix.rings.kicks);
    try std.testing.expectEqual(@as(u32, 0), fix.rings.tx_frames);
}

test "a waiting frame lands in the first free slot" {
    var fix = try Fixture.open();
    defer fix.close();
    try fix.point(1, chain_at);
    fix.rings.receiving = 1 << 1;
    try fix.plant(chain_at, .fsingle, 8, buffer_at);
    try fix.plant(chain_at + desc.size, .fempty, 128, buffer_at + 256);
    _ = fix.far.offer(&frame);

    fix.rings.tick(true);

    const slot = chain_at + desc.size;
    try std.testing.expectEqual(@as(u32, 1), fix.rings.rx_frames);
    try std.testing.expectEqual(desc.Dt.fsingle, try fix.typeAt(slot));
    try std.testing.expectEqual(@as(u32, frame.len), try fix.sizeAt(slot));
    var back = @as([frame.len]u8, @splat(0));
    try fix.core.read(buffer_at + 256, &back);
    try std.testing.expectEqualSlices(u8, &frame, &back);
}

test "a stopped gateway receives nothing" {
    var fix = try Fixture.open();
    defer fix.close();
    try fix.point(0, chain_at);
    fix.rings.receiving = 1;
    try fix.plant(chain_at, .fempty, 128, buffer_at);
    _ = fix.far.offer(&frame);

    fix.rings.tick(false);

    try std.testing.expectEqual(@as(u32, 0), fix.rings.rx_frames);
    try std.testing.expectEqual(@as(usize, 1), fix.far.inbound.count);
}

test "a frame bigger than the slot stays queued instead of being cut" {
    var fix = try Fixture.open();
    defer fix.close();
    try fix.point(0, chain_at);
    fix.rings.receiving = 1;
    try fix.plant(chain_at, .fempty, 16, buffer_at);
    _ = fix.far.offer(&frame);

    fix.rings.tick(true);

    try std.testing.expectEqual(@as(u32, 1), fix.rings.refused.too_big);
    try std.testing.expectEqual(@as(u32, 0), fix.rings.rx_frames);
    try std.testing.expectEqual(@as(usize, 1), fix.far.inbound.count);
}

test "a ring with no free slot is backpressure, and the frame stays" {
    var fix = try Fixture.open();
    defer fix.close();
    try fix.point(0, chain_at);
    fix.rings.receiving = 1;
    try fix.plant(chain_at, .link, 0, chain_at);
    _ = fix.far.offer(&frame);

    fix.rings.tick(true);

    try std.testing.expectEqual(@as(u32, 1), fix.rings.refused.looped);
    try std.testing.expectEqual(@as(usize, 1), fix.far.inbound.count);
}

test "a ring that cycles two links long ends the walk" {
    var fix = try Fixture.open();
    defer fix.close();
    try fix.point(0, chain_at);
    fix.rings.receiving = 1;
    try fix.plant(chain_at, .link, 0, chain_at + desc.size);
    try fix.plant(chain_at + desc.size, .link, 0, chain_at);
    _ = fix.far.offer(&frame);

    fix.rings.tick(true);

    try std.testing.expectEqual(@as(u32, 1), fix.rings.refused.looped);
    try std.testing.expectEqual(@as(u32, 0), fix.rings.rx_frames);
}

test "a chain of links is followed to the free slot behind them" {
    var fix = try Fixture.open();
    defer fix.close();
    try fix.point(0, chain_at);
    fix.rings.receiving = 1;
    try fix.plant(chain_at, .link, 0, chain_at + 0x40);
    try fix.plant(chain_at + 0x40, .fempty, 128, buffer_at);
    _ = fix.far.offer(&frame);

    fix.rings.tick(true);

    try std.testing.expectEqual(@as(u32, 1), fix.rings.rx_frames);
    try std.testing.expectEqual(desc.Dt.fsingle, try fix.typeAt(chain_at + 0x40));
}

test "every configured reception queue is drained, not only the last" {
    var fix = try Fixture.open();
    defer fix.close();
    try fix.point(0, chain_at);
    try fix.point(2, chain_at + 0x40);
    fix.rings.receiving = 0b101;
    try fix.plant(chain_at, .fempty, 128, buffer_at);
    try fix.plant(chain_at + 0x40, .fempty, 128, buffer_at + 256);
    _ = fix.far.offer(&frame);
    _ = fix.far.offer(&frame);

    fix.rings.tick(true);

    try std.testing.expectEqual(@as(u32, 2), fix.rings.rx_frames);
}

test "a slot pointing outside RAM is not written into" {
    var fix = try Fixture.open();
    defer fix.close();
    try fix.point(0, chain_at);
    fix.rings.receiving = 1;
    try fix.plant(chain_at, .fempty, 128, 0x4000_0000);
    _ = fix.far.offer(&frame);

    fix.rings.tick(true);

    try std.testing.expectEqual(@as(u32, 1), fix.rings.refused.off_ram);
    try std.testing.expectEqual(@as(u32, 0), fix.rings.rx_frames);
}

test "an engine that moved nothing is quiet" {
    var fix = try Fixture.open();
    defer fix.close();
    try std.testing.expect(fix.rings.quiet());
    fix.rings.kick(1, 0, false);
    try std.testing.expect(!fix.rings.quiet());
}
