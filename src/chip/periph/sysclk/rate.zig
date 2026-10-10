//! Each core's clock, in Hz, derived from the modelled clock tree
//! (RA8EMU-515, slice 1).
//!
//! CPUCLKn = the SCKSCR source's frequency / the core's SCKDIVCR2 nibble
//! (CPUCLK0 bits 3:0, CPUCLK1 bits 7:4; HUM R01UH1065EJ0130 9.2.3). A PLL
//! source is its own input / PLIDIV x PLLMUL / PLODIVP.
//!
//! Only frequencies the firmware tree states are used:
//!   MOCO 8 MHz and HOCO 20 MHz   ra8_cgc.h lines 11, 13 and 53
//!   main XTAL 24 MHz             ra8_cgc.h line 204, and the EK-RA8D2
//!                                quickstart PLLCCR 0xFA02 / PLLCCR2 0x451
//!                                (24 / 3 x 250 / 2 = 1 GHz, pll.zig)
//! LOCO and the sub-clock have no frequency there, so they answer null, as
//! does a prohibited divider or PLL code. Null means "rate unknown": a
//! caller keeps the rate it had rather than guessing one.
const sysclk = @import("sysclk.zig");
const div = @import("div.zig");
const pll_config = @import("../pll/config.zig");
const pll_div = @import("../pll/div.zig");

pub const moco_hz: u64 = 8_000_000;
pub const hoco_hz: u64 = 20_000_000;
pub const xtal_hz: u64 = 24_000_000;

/// One PLL's configuration words, as the board's PLL unit holds them.
pub const PllConfig = pll_config.Config;

pub const Core = enum { cpu0, cpu1 };

/// What the rate is derived from: the selected source, the SCKDIVCR2 word
/// and both PLLs' configuration.
pub const Inputs = struct {
    source: sysclk.Source,
    divcr2: u16,
    pll1: pll_config.Config,
    pll2: pll_config.Config,
};

/// CPUCLK0 or CPUCLK1 in Hz, or null when the tree does not say.
pub fn coreHz(inputs: Inputs, core: Core) ?u64 {
    const at = switch (core) {
        .cpu0 => div.shift2.cpuclk0,
        .cpu1 => div.shift2.cpuclk1,
    };
    const ratio = div.ratio(div.codeAt(inputs.divcr2, at)) orelse return null;
    return (sourceHz(inputs) orelse return null) / ratio;
}

/// The frequency of the selected source, before the core divider.
pub fn sourceHz(inputs: Inputs) ?u64 {
    return switch (inputs.source) {
        .moco => moco_hz,
        .hoco => hoco_hz,
        .main => xtal_hz,
        .pll1 => pllP(inputs.pll1),
        .pll2 => pllP(inputs.pll2),
        .loco, .subck, .reserved => null,
    };
}

/// A PLL's P output: input / PLIDIV x PLLMUL / PLODIVP. The multiplier is
/// in quarters (PLLMULNF), so the product is taken in quarters too.
pub fn pllP(config: pll_config.Config) ?u64 {
    const input: u64 = switch (config.source()) {
        .main => xtal_hz,
        .hoco => hoco_hz,
    };
    const in_ratio = config.inputRatio() orelse return null;
    const p = config.outputRatios()[0] orelse return null;
    const quarters: u64 = config.multiplier().quarters;
    if (quarters == 0) return null;
    return input * quarters / (4 * @as(u64, in_ratio) * p);
}
