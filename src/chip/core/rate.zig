//! How long CPU1's turn is, given how fast it runs against CPU0.
//!
//! The interleave gives CPU1 a turn after each of CPU0's rounds. Both cores
//! are clocked from the same system clock source, each through its own
//! SCKDIVCR2 divider: CPUCK0 in bits 3:0 and CPUCK1 in bits 7:4 (RA8D2 HUM
//! R01UH1065EJ0130 Rev 1.30, 9.2.3 p 328 to 329). So in the time CPU0 runs a
//! round, CPU1 runs round * div0 / div1 cycles, with no frequency needed.
//! At reset both dividers are /1 and the turn is the whole round, which is
//! what the interleave has always done. The bring-up word 0x2020
//! (CPUCLK0 /1, CPUCLK1 /4) gives CPU1 a quarter of a round, which matches
//! the datasheet ceilings: 1 GHz against 250 MHz.
//!
//! A cycle is charged as an instruction here, the same simplification the
//! time base makes. A code the HUM prohibits leaves the turn at a full round
//! rather than guessing a ratio, and a turn is never shorter than one
//! instruction, so a slow CPU1 is slowed down and never starved.

const div = @import("../periph/sysclk/div.zig");

/// CPU1's turn, in instructions, for one CPU0 round of `round` instructions
/// under the divider word `sckdivcr2`.
pub fn turn(round: u32, sckdivcr2: u32) u32 {
    const div0 = div.ratio(div.codeAt(sckdivcr2, div.shift2.cpuclk0)) orelse return round;
    const div1 = div.ratio(div.codeAt(sckdivcr2, div.shift2.cpuclk1)) orelse return round;
    const share = @as(u64, round) * div0 / div1;
    return @intCast(@max(@min(share, @as(u64, @import("std").math.maxInt(u32))), 1));
}
