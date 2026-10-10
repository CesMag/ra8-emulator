//! Tests for src/chip/periph/scs_alias.zig.

const std = @import("std");
const ra8 = @import("ra8");
const alias = ra8.chip.periph.scs_alias;

const vtor: u32 = 0xE000_ED08;
const vtor_ns: u32 = 0xE002_ED08;

fn target(address: u32, secure: bool) alias.Target {
    return switch (alias.route(address, secure)) {
        .register => |t| t,
        else => unreachable,
    };
}

test "the alias windows sit 0x20000 above the normal ones" {
    try std.testing.expectEqual(@as(u32, 0xE002_E000), alias.scs_ns.first);
    try std.testing.expectEqual(@as(u32, 0xE002_EFFF), alias.scs_ns.last);
    try std.testing.expectEqual(@as(u32, 0xE002_ED00), alias.scb_ns.first);
    try std.testing.expectEqual(@as(u32, 0xE002_ED8F), alias.scb_ns.last);
}

test "the normal window answers in the state of the caller" {
    try std.testing.expectEqual(alias.View.secure, target(vtor, true).view);
    try std.testing.expectEqual(alias.View.non_secure, target(vtor, false).view);
    try std.testing.expectEqual(vtor, target(vtor, false).address);
}

test "Secure code reaches the Non-secure bank through the alias" {
    const t = target(vtor_ns, true);
    try std.testing.expectEqual(vtor, t.address);
    try std.testing.expectEqual(alias.View.non_secure, t.view);
}

test "Non-secure code on the alias window gets RES0" {
    const r = alias.route(vtor_ns, false);
    try std.testing.expectEqual(vtor, r.res0);
    try std.testing.expect(alias.route(0xE002_E000, false) == .res0);
}

test "the window edges are inclusive and nothing past them routes" {
    try std.testing.expectEqual(@as(u32, 0xE000_E000), target(0xE002_E000, true).address);
    try std.testing.expectEqual(@as(u32, 0xE000_EFFF), target(0xE002_EFFF, true).address);
    try std.testing.expect(alias.route(0xE002_DFFF, true) == .outside);
    try std.testing.expect(alias.route(0xE002_F000, true) == .outside);
    try std.testing.expect(alias.route(0xE000_DFFF, false) == .outside);
}

test "isScb takes either window and nothing beside them" {
    try std.testing.expect(alias.isScb(vtor));
    try std.testing.expect(alias.isScb(vtor_ns));
    try std.testing.expect(!alias.isScb(0xE000_ED90));
    try std.testing.expect(!alias.isScb(0xE002_ECFF));
}

const itns0: u32 = 0xE000_E380;
const itns15: u32 = 0xE000_E3BC;

test "Non-secure code reads NVIC_ITNS as RES0 on the normal window" {
    try std.testing.expectEqual(itns0, alias.route(itns0, false).res0);
    try std.testing.expectEqual(itns15, alias.route(itns15, false).res0);
    try std.testing.expectEqual(itns15 + 3, alias.route(itns15 + 3, false).res0);
}

test "Secure code reaches NVIC_ITNS itself on the normal window" {
    const t = target(itns0, true);
    try std.testing.expectEqual(itns0, t.address);
    try std.testing.expectEqual(alias.View.secure, t.view);
}

test "the Non-secure view of NVIC_ITNS through the alias is RES0 for Secure code too" {
    try std.testing.expectEqual(itns0, alias.route(itns0 + alias.offset, true).res0);
    try std.testing.expectEqual(itns0, alias.route(itns0 + alias.offset, false).res0);
}

test "the words either side of NVIC_ITNS stay registers for Non-secure code" {
    try std.testing.expectEqual(alias.View.non_secure, target(itns0 - 4, false).view);
    try std.testing.expectEqual(alias.View.non_secure, target(itns15 + 4, false).view);
}

test "the ITNS span is the one src/chip/periph/itns.zig names" {
    try std.testing.expectEqual(ra8.chip.periph.nvic.itns.base, alias.itns.first);
    try std.testing.expectEqual(ra8.chip.periph.nvic.itns.last + 3, alias.itns.last);
}
