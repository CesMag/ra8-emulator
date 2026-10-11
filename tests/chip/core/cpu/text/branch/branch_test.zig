//! Covers src/chip/core/cpu/text/branch/branch.zig against its parity digest.
const parity = @import("../parity.zig");

test "every 16-bit branch encoding matches its parity digest" {
    try parity.expectGroupMatches("branch");
}
