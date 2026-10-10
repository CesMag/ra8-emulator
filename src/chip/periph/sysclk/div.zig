//! The SCKDIVCR / SCKDIVCR2 divider nibbles, and what each code divides by.
//!
//! (HUM Ch 9.2.6 "SCKDIVCR" and 9.2.7 "SCKDIVCR2".) Both registers are bags of
//! four-bit fields, one per clock domain, and each field holds a divider code
//! rather than a ratio. The shifts come from ra8_cgc_regs.h: the
//! ra8_sckdivcr_shift_t enum for the eight in SCKDIVCR, and
//! ra8_sckdivcr2_shift_t for the four in SCKDIVCR2.
//!
//! TWO RUNS OF CODES. ra8_clock_div_t runs div_1 = 0 through div_64 = 6, so a
//! code of N up to 6 divides by 2^N. The HUM's own field tables (RA8D2
//! R01UH1065EJ0130 Rev 1.30, 9.2.2 p 328 and 9.2.3 p 329) add a second run:
//! 8 = /3, 9 = /6, 10 = /12, 11 = /24. Every other code is "setting
//! prohibited", and `ratio` answers null for it so the report says the code
//! rather than inventing a divisor.
//!
//! This file is the decode alone. What the tree does with a programmed
//! divider, and the protection in front of the registers, is `sysclk.zig`.

/// Nibble positions in SCKDIVCR (ra8_sckdivcr_shift_t).
pub const shift = struct {
    pub const pckd: u5 = 0;
    pub const pckc: u5 = 4;
    pub const pckb: u5 = 8;
    pub const pcka: u5 = 12;
    pub const bck: u5 = 16;
    pub const pcke: u5 = 20;
    pub const ick: u5 = 24;
    pub const fck: u5 = 28;
};

/// Nibble positions in SCKDIVCR2 (ra8_sckdivcr2_shift_t).
pub const shift2 = struct {
    pub const cpuclk0: u5 = 0;
    pub const cpuclk1: u5 = 4;
    pub const npuclk: u5 = 8;
    pub const mriclk: u5 = 12;
};

/// The highest power-of-two code (div_64).
pub const code_max: u4 = 6;

/// The first of the HUM's divide-by-three codes (8 = /3).
pub const code_thirds: u4 = 8;

/// What a divider code divides by, or null when the HUM marks the code
/// prohibited.
pub fn ratio(code: u4) ?u32 {
    if (code <= code_max) return @as(u32, 1) << code;
    if (code < code_thirds or code > code_thirds + 3) return null;
    return @as(u32, 3) << (code - code_thirds);
}

/// One clock domain: the name the report uses and the nibble it reads.
pub const Domain = struct { name: []const u8, at: u5 };

/// SCKDIVCR's eight domains, fastest-named first so the report reads the way
/// the HUM table does.
pub const domains = [_]Domain{
    .{ .name = "FCLK", .at = shift.fck },
    .{ .name = "ICLK", .at = shift.ick },
    .{ .name = "PCLKE", .at = shift.pcke },
    .{ .name = "BCLK", .at = shift.bck },
    .{ .name = "PCLKA", .at = shift.pcka },
    .{ .name = "PCLKB", .at = shift.pckb },
    .{ .name = "PCLKC", .at = shift.pckc },
    .{ .name = "PCLKD", .at = shift.pckd },
};

/// SCKDIVCR2's four domains.
pub const domains2 = [_]Domain{
    .{ .name = "CPUCLK0", .at = shift2.cpuclk0 },
    .{ .name = "CPUCLK1", .at = shift2.cpuclk1 },
    .{ .name = "NPUCLK", .at = shift2.npuclk },
    .{ .name = "MRICLK", .at = shift2.mriclk },
};

/// The code sitting in one nibble of a divider word.
pub fn codeAt(word: u32, at: u5) u4 {
    return @truncate(word >> at);
}
