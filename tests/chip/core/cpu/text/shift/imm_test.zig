//! Covers src/chip/core/cpu/text/shift/imm.zig against its parity digest.
const parity = @import("../parity.zig");

test "every shift_imm encoding matches its parity digest" {
    try parity.expectGroupMatches("shift_imm");
}
