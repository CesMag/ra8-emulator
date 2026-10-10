//! Covers src/chip/periph/ssie/ssie_reset.zig.
const std = @import("std");
const reset = @import("ra8").chip.periph.ssie_reset;

test "only a rising edge of SSIRST asks for the reset" {
    try std.testing.expect(reset.asserted(0, reset.mask.ssirst));
    try std.testing.expect(!reset.asserted(reset.mask.ssirst, reset.mask.ssirst));
    try std.testing.expect(!reset.asserted(reset.mask.ssirst, 0));
    try std.testing.expect(!reset.asserted(0, 0));
}

test "the FIFO reset bits are not the software reset" {
    // RFRST | TFRST, which ssie_fifo.zig owns.
    try std.testing.expect(!reset.asserted(0, 0x0000_0003));
}

test "the reset keeps every SSICR bit but the two enables" {
    try std.testing.expectEqual(@as(u32, 0), reset.control(reset.clears.enables));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFC), reset.control(0xFFFF_FFFF));
    try std.testing.expectEqual(@as(u32, 0x0000_0040), reset.control(0x0000_0043));
}
