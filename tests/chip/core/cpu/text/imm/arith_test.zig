//! Covers src/chip/core/cpu/text/imm_arith.zig against its parity digest.
const parity = @import("../parity.zig");
const samples = @import("../imm_samples.zig");

test "imm_arith matches its parity digest over every hw1 and sampled hw2" {
    try parity.expectWideGroupMatches("imm_arith", samples.hw1_mask, samples.hw1_value, &samples.hw2);
}
