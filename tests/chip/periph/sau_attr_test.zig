//! Tests for src/chip/periph/sau_attr.zig; also pulls in idau_test.zig, since
//! tests/all.zig is at its line limit.

const std = @import("std");
const ra8 = @import("ra8");
const sau = ra8.chip.periph.sau;
const mod = sau.attribution;

const enable: u32 = 1 << 0;
const allns: u32 = 1 << 1;

/// A SAU with region `index` spanning [base, limit] and the given NSC bit.
fn program(unit: *sau.Sau, index: usize, base: u32, limit: u32, nsc: bool) void {
    const rlar = (limit & 0xFFFF_FFE0) | (if (nsc) @as(u32, 2) else 0) | 1;
    unit.table[index] = sau.Region.fromPair(base, rlar);
}

test "a disabled SAU makes everything Secure" {
    const unit = sau.Sau{};
    const got = mod.fromSau(&unit, 0x2200_0000);
    try std.testing.expectEqual(mod.State.secure, got.state);
    try std.testing.expectEqual(@as(?u8, null), got.region);
}

test "a disabled SAU with ALLNS makes everything Non-secure" {
    const unit = sau.Sau{ .ctrl = allns };
    try std.testing.expectEqual(mod.State.non_secure, mod.fromSau(&unit, 0x2200_0000).state);
}

test "an address in one enabled region is Non-secure and names it" {
    var unit = sau.Sau{ .ctrl = enable };
    program(&unit, 3, 0x2208_0000, 0x220F_FFFF, false);
    const got = mod.fromSau(&unit, 0x2208_1000);
    try std.testing.expectEqual(mod.State.non_secure, got.state);
    try std.testing.expectEqual(@as(?u8, 3), got.region);
}

test "a region with NSC set is Non-secure callable" {
    var unit = sau.Sau{ .ctrl = enable };
    program(&unit, 0, 0x0200_F000, 0x0200_FFFF, true);
    try std.testing.expectEqual(mod.State.callable, mod.fromSau(&unit, 0x0200_F020).state);
}

test "the region limit is inclusive to the last byte of its granule" {
    var unit = sau.Sau{ .ctrl = enable };
    program(&unit, 0, 0x2208_0000, 0x220F_FFE0, false);
    try std.testing.expectEqual(mod.State.non_secure, mod.fromSau(&unit, 0x220F_FFFF).state);
    try std.testing.expectEqual(mod.State.secure, mod.fromSau(&unit, 0x2210_0000).state);
}

test "an address in no region is Secure even with ALLNS" {
    var unit = sau.Sau{ .ctrl = enable | allns };
    program(&unit, 0, 0x2208_0000, 0x220F_FFFF, false);
    try std.testing.expectEqual(mod.State.secure, mod.fromSau(&unit, 0x2200_0000).state);
}

test "an address in two regions is Secure with no region named" {
    var unit = sau.Sau{ .ctrl = enable };
    program(&unit, 0, 0x2208_0000, 0x220F_FFFF, false);
    program(&unit, 1, 0x220C_0000, 0x2213_FFFF, true);
    const got = mod.fromSau(&unit, 0x220C_0000);
    try std.testing.expectEqual(mod.State.secure, got.state);
    try std.testing.expectEqual(@as(?u8, null), got.region);
}

test "a disabled region covers nothing" {
    var unit = sau.Sau{ .ctrl = enable };
    unit.table[0] = sau.Region.fromPair(0x2208_0000, 0x220F_FFE0);
    try std.testing.expectEqual(mod.State.secure, mod.fromSau(&unit, 0x2208_0000).state);
}

test "the IDAU can only make the answer stricter" {
    var unit = sau.Sau{ .ctrl = enable };
    program(&unit, 0, 0x2208_0000, 0x220F_FFFF, false);
    program(&unit, 1, 0x0200_F000, 0x0200_FFFF, true);
    const at_ns: u32 = 0x2208_0000;
    const at_nsc: u32 = 0x0200_F000;
    try std.testing.expectEqual(mod.State.non_secure, mod.attribute(&unit, .{}, at_ns).state);
    try std.testing.expectEqual(mod.State.callable, mod.attribute(&unit, .{ .state = .callable }, at_ns).state);
    try std.testing.expectEqual(mod.State.secure, mod.attribute(&unit, .{ .state = .secure }, at_ns).state);
    try std.testing.expectEqual(mod.State.callable, mod.attribute(&unit, .{}, at_nsc).state);
    try std.testing.expectEqual(mod.State.secure, mod.attribute(&unit, .{ .state = .secure }, at_nsc).state);
}

test "the system and debug ranges are exempt whatever the SAU says" {
    const unit = sau.Sau{};
    for ([_]u32{ 0xE000_0000, 0xE000_2FFF, 0xE000_ED00, 0xE002_ED08, 0xE004_0000, 0xE00F_FFFC }) |at| {
        try std.testing.expect(mod.attribute(&unit, .{}, at).exempt);
    }
    for ([_]u32{ 0xE000_3000, 0xE000_DFFF, 0xE002_0000, 0xE00F_EFFF, 0x4000_0000 }) |at| {
        try std.testing.expect(!mod.attribute(&unit, .{}, at).exempt);
    }
}

test "an IDAU exemption is honoured and its region carried" {
    const unit = sau.Sau{ .ctrl = enable };
    const got = mod.attribute(&unit, .{ .exempt = true, .region = 7 }, 0x4000_0000);
    try std.testing.expect(got.exempt);
    try std.testing.expectEqual(@as(?u8, 7), got.idau_region);
}

test {
    _ = @import("idau_test.zig");
}
