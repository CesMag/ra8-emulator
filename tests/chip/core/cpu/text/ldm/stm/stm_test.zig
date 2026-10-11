//! Covers src/chip/core/cpu/text/ldm_stm.zig against its parity digest.
const parity = @import("../../parity.zig");

test "every 16-bit ldm_stm encoding matches its parity digest" {
    try parity.expectGroupMatches("ldm_stm");
}
