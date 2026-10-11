//! Covers src/chip/core/cpu/text/extend/wide.zig against its parity digest.
const parity = @import("../parity.zig");
const samples = @import("../extend_samples.zig");

test "extend_wide matches its parity digest over every hw1 and sampled hw2" {
    try parity.expectWideGroupMatches("extend_wide", samples.hw1_mask, samples.hw1_value, &samples.hw2);
}
