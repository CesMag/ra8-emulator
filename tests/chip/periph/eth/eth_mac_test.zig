//! MRMAC0/MRMAC1: the address a store only reaches while the port is in
//! CONFIG.
const std = @import("std");
const ra8 = @import("ra8");
const eth_mac = ra8.chip.periph.eth_mac;
const eth_mode = ra8.chip.periph.eth_mode;

const example = [_]u8{ 0x02, 0x11, 0x22, 0x33, 0x44, 0x55 };

fn mrmac0Of(mac: [6]u8) u32 {
    return (@as(u32, mac[0]) << 8) | @as(u32, mac[1]);
}

fn mrmac1Of(mac: [6]u8) u32 {
    return (@as(u32, mac[2]) << 24) | (@as(u32, mac[3]) << 16) |
        (@as(u32, mac[4]) << 8) | @as(u32, mac[5]);
}

test "CONFIG is the only mode a store lands in" {
    try std.testing.expect(eth_mac.takes(.config));
    for ([_]eth_mode.Mode{ .reset, .disable, .operation }) |mode| {
        try std.testing.expect(!eth_mac.takes(mode));
    }
}

test "a store in CONFIG programs the address" {
    var mac = eth_mac.Address{};
    mac.write(.config, eth_mac.off.mrmac0, 4, mrmac0Of(example));
    mac.write(.config, eth_mac.off.mrmac1, 4, mrmac1Of(example));
    try std.testing.expectEqualSlices(u8, &example, &mac.octets());
    try std.testing.expectEqual(@as(u32, 2), mac.stores);
    try std.testing.expectEqual(@as(u32, 0), mac.ignored);
    try std.testing.expect(mac.programmed());
}

test "a store off a running port is swallowed and counted" {
    var mac = eth_mac.Address{};
    mac.write(.operation, eth_mac.off.mrmac0, 4, mrmac0Of(example));
    mac.write(.operation, eth_mac.off.mrmac1, 4, mrmac1Of(example));
    try std.testing.expectEqual(@as(u32, 0), mac.read(eth_mac.off.mrmac0, 4));
    try std.testing.expectEqual(@as(u32, 0), mac.read(eth_mac.off.mrmac1, 4));
    try std.testing.expectEqual(@as(u32, 0), mac.stores);
    try std.testing.expectEqual(@as(u32, 2), mac.ignored);
    try std.testing.expect(!mac.programmed());
}

test "a store before the port reaches CONFIG is swallowed too" {
    var mac = eth_mac.Address{};
    for ([_]eth_mode.Mode{ .reset, .disable }) |mode| {
        mac.write(mode, eth_mac.off.mrmac1, 4, 0xAABBCCDD);
    }
    try std.testing.expectEqual(@as(u32, 0), mac.mrmac1);
    try std.testing.expectEqual(@as(u32, 2), mac.ignored);
}

test "a refused store leaves an address already programmed standing" {
    var mac = eth_mac.Address{};
    mac.write(.config, eth_mac.off.mrmac1, 4, mrmac1Of(example));
    mac.write(.operation, eth_mac.off.mrmac1, 4, 0);
    try std.testing.expectEqual(mrmac1Of(example), mac.mrmac1);
    try std.testing.expectEqual(@as(u32, 1), mac.stores);
    try std.testing.expectEqual(@as(u32, 1), mac.ignored);
}

test "halfword stores build the address between them" {
    var mac = eth_mac.Address{};
    mac.write(.config, eth_mac.off.mrmac1, 2, mrmac1Of(example) & 0xFFFF);
    mac.write(.config, eth_mac.off.mrmac1 + 2, 2, mrmac1Of(example) >> 16);
    try std.testing.expectEqual(mrmac1Of(example), mac.mrmac1);
    try std.testing.expectEqual(@as(u32, 2), mac.stores);
}

test "a narrow read is cut to the lanes it names" {
    var mac = eth_mac.Address{};
    mac.write(.config, eth_mac.off.mrmac1, 4, 0xAABBCCDD);
    try std.testing.expectEqual(@as(u32, 0xDD), mac.read(eth_mac.off.mrmac1, 1));
    try std.testing.expectEqual(@as(u32, 0xAA), mac.read(eth_mac.off.mrmac1 + 3, 1));
    try std.testing.expectEqual(@as(u32, 0xAABB), mac.read(eth_mac.off.mrmac1 + 2, 2));
}

test "a port that never touched the pair stays out of the report" {
    const mac = eth_mac.Address{};
    try std.testing.expect(mac.quiet());
}
