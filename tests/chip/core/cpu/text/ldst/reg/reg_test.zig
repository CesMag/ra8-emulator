//! Covers src/chip/core/cpu/text/ldst/reg/reg.zig against its parity digest.
const parity = @import("../../parity.zig");

test "every 16-bit ldst_reg encoding matches its parity digest" {
    try parity.expectGroupMatches("ldst_reg");
}
