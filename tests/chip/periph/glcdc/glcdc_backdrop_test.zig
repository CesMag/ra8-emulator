//! Covers src/chip/periph/glcdc/glcdc_backdrop.zig: what the panel does when the
//! output stage is on and no graphics layer reads a byte (RA8EMU-489).
const std = @import("std");
const ra8 = @import("ra8");

const glcdc = ra8.chip.periph.glcdc;
const backdrop = glcdc.backdrop;
const pdctr = ra8.chip.periph.pdctr;
const prcr = ra8.chip.periph.prcr;

const layer1 = glcdc.win_base + glcdc.off.layer_base;
const bg_en = glcdc.win_base + glcdc.off.bg_en;

fn unlockedGuard() prcr.Prcr {
    var guard = prcr.Prcr.init();
    guard.write(prcr.win_base, 2, prcr.unlockWord(pdctr.guard));
    return guard;
}

fn poweredDomain(guard: *const prcr.Prcr) pdctr.Pdctr {
    var domain = pdctr.Pdctr.init(guard, .graphics);
    domain.write(pdctr.Domain.graphics.base(), 1, 0);
    return domain;
}

test "a background-only panel with no pixel clock is refused as unclocked" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = glcdc.Glcdc.init(&domain);
    unit.write(bg_en, 4, glcdc.field.bg_en);
    try std.testing.expect(!backdrop.anyLayerReading(&unit));
    try std.testing.expectEqual(@as(?ra8.chip.periph.glcdc_scan.Picture, null), unit.scanOut());
    try std.testing.expectEqual(@as(u32, 1), unit.scanner.count(.unclocked));
    try std.testing.expectEqual(@as(u32, 0), unit.scanner.count(.no_layer));
}

test "with the output stage off there is still no layer and no frame" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = glcdc.Glcdc.init(&domain);
    try std.testing.expectEqual(@as(?ra8.chip.periph.glcdc_scan.Picture, null), unit.scanOut());
    try std.testing.expectEqual(@as(u32, 1), unit.scanner.count(.no_layer));
    try std.testing.expectEqual(@as(u32, 0), unit.scanner.count(.unclocked));
}

test "a layer with RENB set over a descriptor nobody can believe is not painted over" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = glcdc.Glcdc.init(&domain);
    unit.write(bg_en, 4, glcdc.field.bg_en);
    unit.write(layer1 + glcdc.off.flmrd, 4, 1);
    try std.testing.expect(backdrop.anyLayerReading(&unit));
    try std.testing.expectEqual(@as(?ra8.chip.periph.glcdc_scan.Picture, null), unit.scanOut());
    try std.testing.expectEqual(@as(u32, 1), unit.scanner.count(.no_layer));
}
