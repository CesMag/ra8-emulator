//! Tests for src/chip/periph/registry.zig.
const std = @import("std");
const ra8 = @import("ra8");
const mod = ra8.chip.periph.registry;

const Block = mod.Block;
const Bus = mod.Bus;
const Error = mod.Error;
const base = mod.base;
const ns_base = mod.ns_base;
const size = mod.size;

const TestBlock = struct {
    hits: u32 = 0,
    last: u32 = 0,

    fn read(context: *anyopaque, address: u32, width: u3) u32 {
        _ = width;
        const self: *TestBlock = @ptrCast(@alignCast(context));
        self.hits += 1;
        return address;
    }

    fn write(context: *anyopaque, address: u32, width: u3, value: u32) void {
        _ = address;
        _ = width;
        const self: *TestBlock = @ptrCast(@alignCast(context));
        self.last = value;
    }

    fn descriptor(self: *TestBlock, at: u32, span: u32) Block {
        return .{
            .name = "test",
            .base = at,
            .size = span,
            .context = self,
            .readFn = read,
            .writeFn = write,
        };
    }
};
test "an unwritten register alternates so a ready-bit poll completes" {
    var bus = Bus.init(std.testing.allocator);
    defer bus.deinit();
    const status = base + 0x1234;
    try std.testing.expectEqual(@as(u32, 0), bus.read(status, 4));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), bus.read(status, 4));
    try std.testing.expectEqual(@as(u32, 0), bus.read(status, 4));
}

test "a written register reads back, masked to the access width" {
    var bus = Bus.init(std.testing.allocator);
    defer bus.deinit();
    const control = base + 0x2000;
    bus.write(control, 4, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), bus.read(control, 4));
    try std.testing.expectEqual(@as(u32, 0xEF), bus.read(control, 1));
    bus.write(control, 2, 0xFFFF_1234);
    try std.testing.expectEqual(@as(u32, 0x1234), bus.read(control, 4));
}

test "the Non-secure alias and the Secure window are one model" {
    var bus = Bus.init(std.testing.allocator);
    defer bus.deinit();
    bus.write(base + 0x40, 4, 0xA5A5_0001);
    try std.testing.expectEqual(@as(u32, 0xA5A5_0001), bus.read(ns_base + 0x40, 4));
    try std.testing.expectEqual(@as(u32, 1), bus.unmodelledAddresses());
}

test "a registered block answers for its own range and nothing else" {
    var bus = Bus.init(std.testing.allocator);
    defer bus.deinit();
    var model = TestBlock{};
    try bus.add(model.descriptor(base + 0x8000, 0x1000));

    try std.testing.expectEqual(base + 0x8010, bus.read(base + 0x8010, 4));
    try std.testing.expectEqual(@as(u32, 1), model.hits);
    bus.write(ns_base + 0x8010, 4, 0x55);
    try std.testing.expectEqual(@as(u32, 0x55), model.last);

    _ = bus.read(base + 0x9000, 4);
    try std.testing.expectEqual(@as(u32, 1), model.hits);
    try std.testing.expectEqual(@as(u32, 2), bus.counters.modelled);
}

test "blocks are disjoint and inside the window" {
    var bus = Bus.init(std.testing.allocator);
    defer bus.deinit();
    var first = TestBlock{};
    var second = TestBlock{};
    try bus.add(first.descriptor(base + 0x8000, 0x1000));
    try std.testing.expectError(Error.OverlappingBlock, bus.add(second.descriptor(base + 0x8800, 0x1000)));
    try std.testing.expectError(Error.OutsideWindow, bus.add(second.descriptor(0x2000_0000, 0x1000)));
}

/// A block that writes down whose access it was served, read off the bus.
const Witness = struct {
    bus: *Bus,
    seen: ?mod.Issuer = null,

    fn read(context: *anyopaque, address: u32, width: u3) u32 {
        _ = address;
        _ = width;
        const self: *Witness = @ptrCast(@alignCast(context));
        self.seen = self.bus.issuer;
        return 0;
    }

    fn write(context: *anyopaque, address: u32, width: u3, value: u32) void {
        _ = address;
        _ = width;
        _ = value;
        const self: *Witness = @ptrCast(@alignCast(context));
        self.seen = self.bus.issuer;
    }
};

test "each core's port stamps its own issuer on the access" {
    var bus = Bus.init(std.testing.allocator);
    defer bus.deinit();
    var witness = Witness{ .bus = &bus };
    try bus.add(.{ .name = "witness", .base = base, .size = 0x10, .context = &witness, .readFn = Witness.read, .writeFn = Witness.write });
    try std.testing.expectEqual(mod.Issuer.cpu0, bus.issuer);
    bus.port(.cpu1).write(base, 4, 1);
    try std.testing.expectEqual(mod.Issuer.cpu1, witness.seen.?);
    _ = bus.port(.cpu0).read(base, 4);
    try std.testing.expectEqual(mod.Issuer.cpu0, witness.seen.?);
    try std.testing.expect(bus.port(.cpu1).bus == &bus);
}

/// A block that keeps a peek: every peek answers `kept`, and reads count.
const PeekBlock = struct {
    inner: TestBlock = .{},
    kept: u32 = 0x0000_00FF,

    fn peek(context: *anyopaque, address: u32, width: u3) u32 {
        _ = address;
        _ = width;
        const self: *PeekBlock = @ptrCast(@alignCast(context));
        return self.kept;
    }
};

test "a block without a peek leaves the word unreadable and counts nothing" {
    var bus = Bus.init(std.testing.allocator);
    defer bus.deinit();
    var block = TestBlock{};
    try bus.add(block.descriptor(base, 0x100));
    try std.testing.expectEqual(@as(?u32, null), bus.peek(base + 4, 4));
    try std.testing.expectEqual(@as(u32, 0), block.hits);
    try std.testing.expectEqual(@as(u64, 0), bus.counters.reads);
}

test "a block's peek answers without a read reaching the block" {
    var bus = Bus.init(std.testing.allocator);
    defer bus.deinit();
    var block = PeekBlock{};
    var described = block.inner.descriptor(base, 0x100);
    described.context = &block;
    described.peekFn = PeekBlock.peek;
    try bus.add(described);
    try std.testing.expectEqual(@as(?u32, 0xFF), bus.peek(base + 4, 4));
    try std.testing.expectEqual(@as(u32, 0), block.inner.hits);
    try std.testing.expectEqual(@as(u64, 0), bus.counters.reads);
}

test "an unmodelled register peeks what was written and nothing before" {
    var bus = Bus.init(std.testing.allocator);
    defer bus.deinit();
    const at = base + 0x40;
    try std.testing.expectEqual(@as(?u32, null), bus.peek(at, 4));
    // The peek left the ready-bit alternation where it was: first read 0.
    try std.testing.expectEqual(@as(u32, 0), bus.read(at, 4));
    bus.write(at, 4, 0x1234_5678);
    try std.testing.expectEqual(@as(?u32, 0x1234_5678), bus.peek(at, 4));
    try std.testing.expectEqual(@as(?u32, 0x78), bus.peek(at, 1));
}
