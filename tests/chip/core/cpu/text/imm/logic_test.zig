//! Covers src/chip/core/cpu/text/imm/logic.zig against its parity digest.
const parity = @import("../parity.zig");
const samples = @import("../imm_samples.zig");

test "imm_logic matches its parity digest over every hw1 and sampled hw2" {
    try parity.expectWideGroupMatches("imm_logic", samples.hw1_mask, samples.hw1_value, &samples.hw2);
}
