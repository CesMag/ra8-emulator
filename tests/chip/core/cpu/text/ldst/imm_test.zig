//! Covers src/chip/core/cpu/text/ldst/imm.zig against its parity digest.
const parity = @import("../parity.zig");

test "every 16-bit ldst_imm encoding matches its parity digest" {
    try parity.expectGroupMatches("ldst_imm");
}
