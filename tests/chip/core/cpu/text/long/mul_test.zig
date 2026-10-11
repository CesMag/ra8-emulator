//! Covers src/chip/core/cpu/text/long/mul.zig against its parity digest.
const parity = @import("../parity.zig");
const samples = @import("../multiply_samples.zig");

test "long_mul matches its parity digest over every hw1 and sampled hw2" {
    try parity.expectWideGroupMatches("long_mul", samples.hw1_mask, samples.hw1_value, &samples.hw2);
}
