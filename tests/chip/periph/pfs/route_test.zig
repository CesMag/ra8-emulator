const std = @import("std");
const ra8 = @import("ra8");
const route = ra8.chip.periph.pfs.route;

const pmr = route.field.pmr;

fn entry(function: u32, in_peripheral: bool) u32 {
    return (function << 24) | (if (in_peripheral) pmr else 0);
}

test "a routed pin moved straight to another function is counted" {
    var order = route.Route{};
    order.observe(entry(3, true), entry(7, true));
    try std.testing.expectEqual(@as(u32, 1), order.glitched);
    try std.testing.expect(!order.quiet());
}

test "the three-store sequence is quiet all the way through" {
    var order = route.Route{};
    const routed_to_three = entry(3, true);
    order.observe(routed_to_three, 0);
    order.observe(0, entry(7, false));
    order.observe(entry(7, false), entry(7, true));
    try std.testing.expect(order.quiet());
}

test "handing a GPIO pin to a peripheral for the first time is not a breach" {
    var order = route.Route{};
    order.observe(0, entry(9, true));
    try std.testing.expect(order.quiet());
}

test "taking a routed pin back to GPIO is not a breach" {
    var order = route.Route{};
    order.observe(entry(9, true), entry(9, false));
    try std.testing.expect(order.quiet());
}

test "changing anything but the function on a routed pin is untouched" {
    var order = route.Route{};
    const before = entry(5, true);
    order.observe(before, before | 0x0000_0400);
    try std.testing.expect(order.quiet());
}

test "the fields are read where ra8_pfs_regs.h puts them" {
    try std.testing.expect(route.routed(entry(0, true)));
    try std.testing.expect(!route.routed(entry(31, false)));
    try std.testing.expectEqual(@as(u32, 31), route.functionOf(entry(31, true)));
    try std.testing.expectEqual(@as(u32, 0), route.functionOf(0xFFFF_FFFF & ~route.field.psel));
}

test "every breach is counted, not just the first" {
    var order = route.Route{};
    order.observe(entry(1, true), entry(2, true));
    order.observe(entry(2, true), entry(3, true));
    try std.testing.expectEqual(@as(u32, 2), order.glitched);
}
