//! Covers src/chip/core/cpu/text/shift/reg.zig against its parity digest.
const parity = @import("../parity.zig");
const samples = @import("../shift_reg_samples.zig");

test "shift_reg matches its parity digest over every hw1 and sampled hw2" {
    try parity.expectWideGroupMatches("shift_reg", samples.hw1_mask, samples.hw1_value, &samples.hw2);
}
