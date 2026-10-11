//! Covers src/chip/core/cpu/text/dp_shifted.zig against its parity digest.
const parity = @import("../parity.zig");
const samples = @import("../dp_shifted_samples.zig");

test "dp_shifted matches its parity digest over every hw1 and sampled hw2" {
    try parity.expectWideGroupMatches("dp_shifted", samples.hw1_mask, samples.hw1_value, &samples.hw2);
}
