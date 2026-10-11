//! Covers src/chip/core/cpu/text/dp_reg.zig against its parity digest.
const parity = @import("../parity.zig");

test "every dp_reg encoding matches its parity digest" {
    try parity.expectGroupMatches("dp_reg");
}
