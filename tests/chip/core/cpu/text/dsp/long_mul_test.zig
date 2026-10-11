//! Covers src/chip/core/cpu/text/dsp/long_mul.zig against its parity digest.
const parity = @import("../parity.zig");
const samples = @import("../dsp_mul_samples.zig");

test "dsp_long_mul matches its parity digest over every hw1 and sampled hw2" {
    try parity.expectWideGroupMatches("dsp_long_mul", 0xFFE0, 0xFBC0, &samples.hw2);
}
