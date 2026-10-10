//! Covers src/chip/core/part.zig: the one thing that differs between the two
//! parts this emulator runs, and the refusal to guess at a third.
const std = @import("std");
const ra8 = @import("ra8");
const part = ra8.chip.core.part;

test "the two parts this emulator models parse by name" {
    try std.testing.expectEqual(part.Part.ra8d2, part.Part.parse("ra8d2").?);
    try std.testing.expectEqual(part.Part.ra8p1, part.Part.parse("ra8p1").?);
}

test "a part this emulator does not model is refused, not defaulted" {
    try std.testing.expectEqual(@as(?part.Part, null), part.Part.parse("ra8m1"));
    try std.testing.expectEqual(@as(?part.Part, null), part.Part.parse("RA8P1"));
    try std.testing.expectEqual(@as(?part.Part, null), part.Part.parse(""));
}

test "only the RA8P1 has an NPU behind it" {
    try std.testing.expect(part.Part.ra8p1.hasNpu());
    try std.testing.expect(!part.Part.ra8d2.hasNpu());
}

test "each part says its own name" {
    try std.testing.expectEqualStrings("RA8D2", part.Part.ra8d2.label());
    try std.testing.expectEqualStrings("RA8P1", part.Part.ra8p1.label());
}

test "CPU0 has a Secure and a Non-secure SysTick" {
    try std.testing.expectEqual(@as(u2, 2), part.cpu0_systicks);
}

test "CPU1 has a Secure and a Non-secure SysTick too" {
    try std.testing.expectEqual(@as(u2, 2), part.cpu1_systicks);
}

test "CPU0 decodes as a Cortex-M85 and CPU1 as a Cortex-M33" {
    const Profile = ra8.chip.core.cpu.decode.profile.Profile;
    try std.testing.expectEqual(Profile.m85, part.cpu0_profile);
    try std.testing.expectEqual(Profile.m33, part.cpu1_profile);
}
