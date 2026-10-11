//! Covers src/chip/core/cpu/text/dsp_mulhi.zig against its parity digest.
const parity = @import("../parity.zig");
const samples = @import("../dsp_mul_samples.zig");

test "dsp_mulhi matches its parity digest over every hw1 and sampled hw2" {
    try parity.expectWideGroupMatches("dsp_mulhi", samples.hw1_mask, samples.hw1_value, &samples.hw2);
}
