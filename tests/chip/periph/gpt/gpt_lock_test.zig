//! GTWP: the password, the WP bit, and what a shut channel turns away.
const std = @import("std");

const ra8 = @import("ra8");
const gpt = ra8.chip.periph.gpt;
const lock = gpt.protection;

const channel0: u32 = gpt.win_base;

fn word(bus: *gpt.Gpt, address: u32) u32 {
    return bus.read(address, 4);
}

test "a store without the password leaves protection alone" {
    var guard = lock.Lock{};
    guard.store(0, 4, 0x0000_0001);
    try std.testing.expect(!guard.shut);
    try std.testing.expectEqual(@as(u32, 0), guard.value());
}

test "the password shuts and reopens the channel" {
    var guard = lock.Lock{};
    guard.store(0, 4, lock.field.lock);
    try std.testing.expect(guard.shut);
    try std.testing.expectEqual(lock.field.wp, guard.value());

    guard.store(0, 4, lock.field.unlock);
    try std.testing.expect(!guard.shut);
    try std.testing.expectEqual(@as(u32, 0), guard.value());
}

test "a word of zero does not reopen a shut channel" {
    var guard = lock.Lock{};
    guard.store(0, 4, lock.field.lock);
    guard.store(0, 4, 0);
    try std.testing.expect(guard.shut);
}

test "a half-word store carrying the password still reaches WP" {
    var guard = lock.Lock{};
    guard.store(0, 2, lock.field.lock);
    try std.testing.expect(guard.shut);
    guard.store(0, 2, lock.field.unlock);
    try std.testing.expect(!guard.shut);
}

test "a byte store of WP alone never carries the password" {
    var guard = lock.Lock{};
    guard.store(0, 1, 0x01);
    try std.testing.expect(!guard.shut);
}

test "a read of GTWP answers the WP bit and never the password" {
    var bus = gpt.Gpt.init();
    bus.write(channel0 + lock.off.gtwp, 4, lock.field.lock);
    try std.testing.expectEqual(lock.field.wp, word(&bus, channel0 + lock.off.gtwp));
}

test "a shut channel drops a store to a register this model interprets" {
    var bus = gpt.Gpt.init();
    bus.write(channel0 + gpt.off.gtpr, 4, 0x0000_1000);
    bus.write(channel0 + lock.off.gtwp, 4, lock.field.lock);

    bus.write(channel0 + gpt.off.gtpr, 4, 0x0000_2000);
    try std.testing.expectEqual(@as(u32, 0x0000_1000), word(&bus, channel0 + gpt.off.gtpr));
    try std.testing.expectEqual(@as(u32, 1), bus.channels[0].guard.refused);

    bus.write(channel0 + lock.off.gtwp, 4, lock.field.unlock);
    bus.write(channel0 + gpt.off.gtpr, 4, 0x0000_2000);
    try std.testing.expectEqual(@as(u32, 0x0000_2000), word(&bus, channel0 + gpt.off.gtpr));
}

test "a shut channel refuses the start request, so the counter stays still" {
    var bus = gpt.Gpt.init();
    bus.write(channel0 + lock.off.gtwp, 4, lock.field.lock);
    bus.write(channel0 + gpt.off.gtstr, 4, 1);
    try std.testing.expect(!bus.channels[0].running());

    bus.write(channel0 + lock.off.gtwp, 4, lock.field.unlock);
    bus.write(channel0 + gpt.off.gtstr, 4, 1);
    try std.testing.expect(bus.channels[0].running());
}

test "protection never covers GTWP itself, or nothing could reopen it" {
    var bus = gpt.Gpt.init();
    bus.write(channel0 + lock.off.gtwp, 4, lock.field.lock);
    bus.write(channel0 + lock.off.gtwp, 4, lock.field.unlock);
    try std.testing.expect(!bus.channels[0].guard.shut);
    try std.testing.expectEqual(@as(u32, 0), bus.channels[0].guard.refused);
}

test "one channel's key says nothing about another's" {
    var bus = gpt.Gpt.init();
    bus.write(channel0 + lock.off.gtwp, 4, lock.field.lock);
    const channel1 = gpt.win_base + gpt.stride;
    bus.write(channel1 + gpt.off.gtpr, 4, 0x0000_4000);
    try std.testing.expectEqual(@as(u32, 0x0000_4000), word(&bus, channel1 + gpt.off.gtpr));
    try std.testing.expectEqual(@as(u32, 0), bus.channels[1].guard.refused);
}

test "a shadowed register keeps taking stores, because no table here names it" {
    var bus = gpt.Gpt.init();
    const gtior = channel0 + 0x34;
    bus.write(channel0 + lock.off.gtwp, 4, lock.field.lock);
    bus.write(gtior, 4, 0x0000_0055);
    try std.testing.expectEqual(@as(u32, 0x0000_0055), word(&bus, gtior));
    try std.testing.expectEqual(@as(u32, 0), bus.channels[0].guard.refused);
}
