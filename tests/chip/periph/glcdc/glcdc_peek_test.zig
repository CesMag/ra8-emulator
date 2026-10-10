//! Covers src/chip/periph/glcdc/glcdc_peek.zig: what a report reads out of the
//! GLCDC after a run, without the side effects of a bus read (RA8EMU-631).
const std = @import("std");
const ra8 = @import("ra8");

const glcdc = ra8.chip.periph.glcdc;
const pdctr = ra8.chip.periph.pdctr;
const prcr = ra8.chip.periph.prcr;

const bg_bgc = glcdc.win_base + glcdc.off.bg_bgc;

test "a powered block peeks the backdrop colour a read would return" {
    var guard = prcr.Prcr.init();
    guard.write(prcr.win_base, 2, prcr.unlockWord(pdctr.guard));
    var domain = pdctr.Pdctr.init(&guard, .graphics);
    domain.write(pdctr.Domain.graphics.base(), 1, 0);
    var unit = glcdc.Glcdc.init(&domain);
    unit.write(bg_bgc, 4, 0x0000_00FF);
    const peek = unit.block().peekFn.?;
    try std.testing.expectEqual(unit.read(bg_bgc, 4), peek(&unit, bg_bgc, 4));
    try std.testing.expectEqual(@as(u32, 0xFF), peek(&unit, bg_bgc, 4));
    try std.testing.expectEqual(@as(u32, 0xFF), peek(&unit, bg_bgc, 1));
}

test "a dark block peeks zero and counts no dark read" {
    const guard = prcr.Prcr.init();
    const domain = pdctr.Pdctr.init(&guard, .graphics);
    var unit = glcdc.Glcdc.init(&domain);
    const before = unit.dark_reads;
    try std.testing.expectEqual(@as(u32, 0), unit.block().peekFn.?(&unit, bg_bgc, 4));
    try std.testing.expectEqual(before, unit.dark_reads);
}
