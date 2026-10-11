//! Covers src/chip/core/cpu/text/dsp_mul16.zig against its parity digest.
const parity = @import("../parity.zig");
const samples = @import("../dsp_mul_samples.zig");

test "dsp_mul16 matches its parity digest over every hw1 and sampled hw2" {
    try parity.expectWideGroupMatches("dsp_mul16", samples.hw1_mask, samples.hw1_value, &samples.hw2);
}
