//! Covers src/components/fault.zig on the MAX17048 fuel gauge: each mode,
//! seen through the I2C registry and the RIIC address phase.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.periph.riic_bus;
const fault = ra8.components.model.fault;
const gauge_mod = ra8.components.max17048;

const Rig = struct {
    gauge: gauge_mod.Gauge = .{},
    wrapper: fault.I2c = undefined,
    registry: bus.Registry = .{},

    fn init(self: *Rig) !void {
        self.wrapper = fault.I2c.wrap(self.gauge.device());
        try self.registry.attach(self.wrapper.device());
    }

    /// Point at VERSION and read its two bytes, as a driver would.
    fn readVersion(self: *Rig) ?[2]u8 {
        const device = self.registry.answering(gauge_mod.address) orelse return null;
        device.write(gauge_mod.reg.version);
        device.stop();
        const again = self.registry.answering(gauge_mod.address) orelse return null;
        var word: [2]u8 = undefined;
        _ = again.read(&word);
        again.stop();
        return word;
    }
};

test "with no fault the gauge answers as itself" {
    var rig = Rig{};
    try rig.init();
    var plain = gauge_mod.Gauge{};
    var bare = bus.Registry{};
    try bare.attach(plain.device());
    const direct = bare.find(gauge_mod.address).?;
    direct.write(gauge_mod.reg.version);
    direct.stop();
    var want: [2]u8 = undefined;
    _ = direct.read(&want);
    try std.testing.expectEqualSlices(u8, &want, &(rig.readVersion().?));
}

test "a disconnected gauge acknowledges nothing" {
    var rig = Rig{};
    try rig.init();
    rig.wrapper.set(.disconnected);
    try std.testing.expect(rig.readVersion() == null);
    try std.testing.expectEqual(@as(u32, 1), rig.wrapper.refused);
    rig.wrapper.set(.none);
    try std.testing.expect(rig.readVersion() != null);
}

test "NACK every third address phase refuses exactly those" {
    var rig = Rig{};
    try rig.init();
    rig.wrapper.set(.{ .nack_every = 3 });
    var answered: [6]bool = undefined;
    for (&answered) |*seen| seen.* = rig.registry.answering(gauge_mod.address) != null;
    try std.testing.expectEqualSlices(bool, &.{ true, true, false, true, true, false }, &answered);
    try std.testing.expectEqual(@as(u32, 2), rig.wrapper.refused);
}

test "a stuck gauge reads back one value" {
    var rig = Rig{};
    try rig.init();
    rig.wrapper.set(.{ .stuck = 0xA5 });
    try std.testing.expectEqualSlices(u8, &.{ 0xA5, 0xA5 }, &(rig.readVersion().?));
}

test "garbage is noise, and the same noise for the same seed" {
    var first = Rig{};
    try first.init();
    first.wrapper.set(.{ .garbage = 7 });
    var second = Rig{};
    try second.init();
    second.wrapper.set(.{ .garbage = 7 });
    const a = first.readVersion().?;
    try std.testing.expectEqualSlices(u8, &a, &(second.readVersion().?));
    var clean = Rig{};
    try clean.init();
    try std.testing.expect(!std.mem.eql(u8, &a, &(clean.readVersion().?)));
}

test "a disconnected gauge stays on the bus but answers no address phase" {
    var gauge = gauge_mod.Gauge{};
    var wrapper = fault.I2c.wrap(gauge.device());
    wrapper.set(.disconnected);
    var registry = bus.Registry{};
    try registry.attach(wrapper.device());
    try std.testing.expect(registry.find(gauge_mod.address) != null);
    try std.testing.expect(registry.answering(gauge_mod.address) == null);
}

test "a slow gauge NACKs after a write until its virtual deadline" {
    var clock = ra8.chip.periph.clocks.timebase.TimeBase{};
    var gauge = gauge_mod.Gauge{};
    var wrapper = fault.I2c.timed(gauge.device(), &clock);
    wrapper.set(.{ .slow_ns = 5_000 });
    var registry = bus.Registry{};
    try registry.attach(wrapper.device());
    const device = registry.answering(gauge_mod.address).?;
    device.write(gauge_mod.reg.version);
    device.stop();
    try std.testing.expect(registry.answering(gauge_mod.address) == null);
    clock.advance(4_999);
    try std.testing.expect(registry.answering(gauge_mod.address) == null);
    clock.advance(1);
    try std.testing.expect(registry.answering(gauge_mod.address) != null);
    try std.testing.expectEqual(@as(u32, 2), wrapper.refused);
}

test "a slow gauge stays ready across reads, and without a clock" {
    var clock = ra8.chip.periph.clocks.timebase.TimeBase{};
    var gauge = gauge_mod.Gauge{};
    var wrapper = fault.I2c.timed(gauge.device(), &clock);
    wrapper.set(.{ .slow_ns = 5_000 });
    var registry = bus.Registry{};
    try registry.attach(wrapper.device());
    const device = registry.answering(gauge_mod.address).?;
    var word: [2]u8 = undefined;
    _ = device.read(&word);
    device.stop();
    try std.testing.expect(registry.answering(gauge_mod.address) != null);
    var bare = fault.I2c.wrap(gauge.device());
    bare.set(.{ .slow_ns = 5_000 });
    const loose = bare.device();
    loose.write(0);
    loose.stop();
    try std.testing.expect(loose.acks());
}

test "a stretching gauge reports its stretch, and other modes report none" {
    var gauge = gauge_mod.Gauge{};
    var wrapper = fault.I2c.wrap(gauge.device());
    try std.testing.expectEqual(@as(u64, 0), wrapper.device().stretch());
    wrapper.set(.{ .stretch_ns = 750 });
    try std.testing.expectEqual(@as(u64, 750), wrapper.device().stretch());
    try std.testing.expect(wrapper.device().acks());
}
