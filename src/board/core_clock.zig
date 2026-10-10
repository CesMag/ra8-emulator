//! Retunes the time base to CPU0's clock as the tree has it (RA8EMU-515,
//! slice 2). Virtual time is CPU0 cycles at CPU0's rate, so when firmware
//! moves CKSEL, a PLL or the CPUCLK0 divider, the nanoseconds a cycle is
//! worth move with it. setRate keeps the time already gone by, so nothing
//! scheduled on the queue jumps. A tree the rate table cannot price (LOCO,
//! the sub-clock, an unconfigured PLL, a prohibited divider) leaves the
//! rate where it was rather than guessing, and so does a tree firmware has
//! not touched yet.
const Board = @import("board.zig").Board;
const sysclk = @import("ra8_chip").periph.sysclk;

/// What the tree and the PLLs say each core runs at.
pub fn inputs(self: *const Board) sysclk.rate.Inputs {
    return .{
        .source = self.tree.source(),
        .divcr2 = self.tree.divcr2,
        .pll1 = self.plls.pll1,
        .pll2 = self.plls.pll2,
    };
}

/// Whether firmware has touched the clock selection or the dividers yet.
/// Until it does, the time base stays at the part's CPU0 ceiling, which is
/// what every run assumed before this file existed: the corpus was recorded
/// that way, and pricing the reset HOCO would slow every boot fifty-fold.
pub fn programmed(self: *const Board) bool {
    return self.tree.selects != 0 or self.tree.programmed != 0;
}

/// Point the time base at CPU0's current rate, when firmware has programmed
/// the tree and the tree names one.
pub fn retune(self: *Board) void {
    if (!programmed(self)) return;
    const hz = sysclk.rate.coreHz(inputs(self), .cpu0) orelse return;
    self.time.base.setRate(hz);
}
