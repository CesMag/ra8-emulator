//! Covers src/chip/core/cpu/text/extend/extend.zig against its parity digest.
const parity = @import("../parity.zig");

test "every extend encoding matches its parity digest" {
    try parity.expectGroupMatches("extend");
}
