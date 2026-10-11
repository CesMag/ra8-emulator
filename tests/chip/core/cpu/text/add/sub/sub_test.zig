//! Covers src/chip/core/cpu/text/add_sub.zig against its parity digest.
const parity = @import("../../parity.zig");

test "every add_sub encoding matches its parity digest" {
    try parity.expectGroupMatches("add_sub");
}
