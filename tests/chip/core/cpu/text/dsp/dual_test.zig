//! Covers src/chip/core/cpu/text/dsp/dual.zig against its parity digest.
const parity = @import("../parity.zig");

/// Every Ra (1111 is the multiply-only form, SP unclaimed) with and without X,
/// Rd/Rm low and high, plus SP as Rd and nonzero hw2[7:5] (unclaimed).
fn table() [16 * 2 * 2 + 2]u16 {
    var out: [16 * 2 * 2 + 2]u16 = undefined;
    var i: usize = 0;
    for (0..16) |ra| {
        for ([_]u16{ 0x0000, 0x0010 }) |x| {
            for ([_]u16{ 0x002, 0xC0C }) |rd_rm| {
                out[i] = (@as(u16, @intCast(ra)) << 12) | x | rd_rm;
                i += 1;
            }
        }
    }
    out[i] = 0xFD02;
    out[i + 1] = 0x3022;
    return out;
}

const hw2 = table();

test "SMLAD and SMUAD match their parity digests" {
    try parity.expectWideGroupMatches("dsp_dual", 0xFFF0, 0xFB20, &hw2);
}

test "SMLSD and SMUSD match their parity digests" {
    try parity.expectWideGroupMatches("dsp_dual", 0xFFF0, 0xFB40, &hw2);
}
