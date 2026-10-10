//! Covers src/chip/core/cpu/decode.zig.
const std = @import("std");
const ra8 = @import("ra8");
const decode = ra8.chip.core.cpu.decode;

test "a known encoding comes back with its class" {
    const hit = decode.decode(.{ .address = 0, .hw1 = 0xBF00, .size = 2 }).?;
    try std.testing.expectEqualStrings("hint", hit.group);
    try std.testing.expect(hit.oracle);
}

test "an encoding no group claims is refused" {
    // ba80, REV with op 0b10: unallocated on Armv8-M. (UDF is claimed: it
    // decodes and is taken as UNDEFINSTR, RA8EMU-282.)
    try std.testing.expect(decode.decode(.{ .address = 0, .hw1 = 0xBA80, .size = 2 }) == null);
}

test {
    _ = @import("profile_test.zig");
}
