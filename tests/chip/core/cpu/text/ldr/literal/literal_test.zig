//! Covers src/chip/core/cpu/text/ldr_literal.zig against its parity digest.
const parity = @import("../../parity.zig");

test "every 16-bit ldr_literal encoding matches its parity digest" {
    try parity.expectGroupMatches("ldr_literal");
}
