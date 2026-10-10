//! Covers src/chip/periph/glcdc.zig: the framebuffer descriptor the display
//! controller is programmed with, and the graphics power domain it lives in.
const std = @import("std");
const ra8 = @import("ra8");

const glcdc = ra8.chip.periph.glcdc;
const pdctr = ra8.chip.periph.pdctr;
const prcr = ra8.chip.periph.prcr;

const layer1 = glcdc.win_base + glcdc.off.layer_base;
const layer2 = layer1 + glcdc.off.layer_stride;
const bg_en = glcdc.win_base + glcdc.off.bg_en;

/// The SDRAM address the display examples draw their framebuffer into.
const fb_base: u32 = 0x6800_0000;

/// A protection model with PRC1 unlocked, which is what a driver does before
/// it can touch the power domain at all.
fn unlockedGuard() prcr.Prcr {
    var guard = prcr.Prcr.init();
    guard.write(prcr.win_base, 2, prcr.unlockWord(pdctr.guard));
    return guard;
}

/// A powered graphics domain: PDDE written as 0, which is the polarity trap.
fn poweredDomain(guard: *const prcr.Prcr) pdctr.Pdctr {
    var domain = pdctr.Pdctr.init(guard, .graphics);
    domain.write(pdctr.Domain.graphics.base(), 1, 0);
    return domain;
}

/// Program one layer for a 480x272 RGB565 panel out of SDRAM.
fn programLayer(unit: *glcdc.Glcdc, layer: u32, base: u32) void {
    unit.write(layer + glcdc.off.flm2, 4, base);
    unit.write(layer + glcdc.off.flm3, 4, 960 << 16);
    unit.write(layer + glcdc.off.flm5, 4, 271 << 16);
    unit.write(layer + glcdc.off.flm6, 4, @as(u32, @backingInt(glcdc.Format.rgb565)) << 28);
    unit.write(layer + glcdc.off.flmrd, 4, 1);
}

test "the block answers from the documented base and span" {
    const guard = prcr.Prcr.init();
    const domain = pdctr.Pdctr.init(&guard, .graphics);
    var unit = glcdc.Glcdc.init(&domain);
    const block = unit.block();
    try std.testing.expectEqual(@as(u32, 0x4034_2000), block.base);
    try std.testing.expectEqual(@as(u32, 0x1500), block.size);
    try std.testing.expect(block.covers(glcdc.win_base + 0x1450));
    try std.testing.expect(!block.covers(glcdc.win_base + glcdc.win_span));
}

test "a run that never touched the controller stays quiet" {
    const guard = prcr.Prcr.init();
    const domain = pdctr.Pdctr.init(&guard, .graphics);
    var unit = glcdc.Glcdc.init(&domain);
    try std.testing.expect(unit.quiet());
}

test "the domain is gated at reset so a write reaches no register" {
    const guard = prcr.Prcr.init();
    const domain = pdctr.Pdctr.init(&guard, .graphics);
    var unit = glcdc.Glcdc.init(&domain);
    unit.write(bg_en, 4, 1);
    try std.testing.expectEqual(@as(u32, 0), unit.writes);
    try std.testing.expectEqual(@as(u32, 1), unit.dropped_unpowered);
    try std.testing.expect(!unit.outputEnabled());
}

test "an unpowered read gives zero and is counted" {
    const guard = prcr.Prcr.init();
    const domain = pdctr.Pdctr.init(&guard, .graphics);
    var unit = glcdc.Glcdc.init(&domain);
    try std.testing.expectEqual(@as(u32, 0), unit.read(bg_en, 4));
    try std.testing.expectEqual(@as(u32, 1), unit.dark_reads);
}

test "a layer programmed while the domain is dark has no framebuffer" {
    const guard = prcr.Prcr.init();
    const domain = pdctr.Pdctr.init(&guard, .graphics);
    var unit = glcdc.Glcdc.init(&domain);
    programLayer(&unit, layer1, fb_base);
    try std.testing.expectEqual(@as(?glcdc.Framebuffer, null), unit.framebuffer());
    try std.testing.expectEqual(@as(u32, 5), unit.dropped_unpowered);
}

test "powering the domain lets the same writes land" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = glcdc.Glcdc.init(&domain);
    unit.write(bg_en, 4, 1);
    try std.testing.expect(unit.outputEnabled());
    try std.testing.expectEqual(@as(u32, 1), unit.writes);
    try std.testing.expectEqual(@as(u32, 0), unit.dropped_unpowered);
}

test "a programmed layer decodes into a framebuffer descriptor" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = glcdc.Glcdc.init(&domain);
    unit.write(bg_en, 4, 1);
    programLayer(&unit, layer1, fb_base);
    const found = unit.framebuffer().?;
    try std.testing.expectEqual(fb_base, found.base);
    try std.testing.expectEqual(@as(u32, 480), found.width);
    try std.testing.expectEqual(@as(u32, 272), found.height);
    try std.testing.expectEqual(@as(u32, 960), found.stride);
    try std.testing.expectEqual(glcdc.Format.rgb565, found.format);
    try std.testing.expectEqual(@as(u8, 1), found.layer);
    try std.testing.expect(found.enabled);
}

test "a layer fetching with the output stage off is still reported, not enabled" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = glcdc.Glcdc.init(&domain);
    programLayer(&unit, layer1, fb_base);
    const found = unit.framebuffer().?;
    try std.testing.expect(!found.enabled);
}

test "layer 1 wins when both layers are fetching" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = glcdc.Glcdc.init(&domain);
    programLayer(&unit, layer1, fb_base);
    programLayer(&unit, layer2, fb_base + 0x10_0000);
    try std.testing.expectEqual(@as(u8, 1), unit.framebuffer().?.layer);
}

test "layer 2 answers when only the lower layer is fetching" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = glcdc.Glcdc.init(&domain);
    programLayer(&unit, layer2, fb_base);
    const found = unit.framebuffer().?;
    try std.testing.expectEqual(@as(u8, 2), found.layer);
    try std.testing.expectEqual(fb_base, found.base);
}

test "a layer with RENB clear is not a framebuffer however it is programmed" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = glcdc.Glcdc.init(&domain);
    programLayer(&unit, layer1, fb_base);
    unit.write(layer1 + glcdc.off.flmrd, 4, 0);
    try std.testing.expectEqual(@as(?glcdc.Framebuffer, null), unit.framebuffer());
}

test "a base outside every RAM window is refused rather than reported" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = glcdc.Glcdc.init(&domain);
    programLayer(&unit, layer1, 0x0002_0000);
    try std.testing.expectEqual(@as(?glcdc.Framebuffer, null), unit.framebuffer());
}

test "a zero stride is refused rather than decoded as a zero-wide panel" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = glcdc.Glcdc.init(&domain);
    programLayer(&unit, layer1, fb_base);
    unit.write(layer1 + glcdc.off.flm3, 4, 0);
    try std.testing.expectEqual(@as(?glcdc.Framebuffer, null), unit.framebuffer());
}

test "a stride past the dimension cap is refused" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = glcdc.Glcdc.init(&domain);
    programLayer(&unit, layer1, fb_base);
    unit.write(layer1 + glcdc.off.flm3, 4, 0xFFFF << 16);
    unit.write(layer1 + glcdc.off.flm6, 4, @as(u32, @backingInt(glcdc.Format.clut8)) << 28);
    try std.testing.expectEqual(@as(?glcdc.Framebuffer, null), unit.framebuffer());
}

test "the width recovery follows the format's fetch width" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = glcdc.Glcdc.init(&domain);
    programLayer(&unit, layer1, fb_base);
    unit.write(layer1 + glcdc.off.flm6, 4, @as(u32, @backingInt(glcdc.Format.argb8888)) << 28);
    const found = unit.framebuffer().?;
    try std.testing.expectEqual(@as(u32, 240), found.width);
    try std.testing.expectEqual(glcdc.Format.argb8888, found.format);
}

test "every format code reports a fetch width" {
    try std.testing.expectEqual(@as(u32, 4), glcdc.Format.argb8888.bytesPerPixel());
    try std.testing.expectEqual(@as(u32, 4), glcdc.Format.rgb888.bytesPerPixel());
    try std.testing.expectEqual(@as(u32, 2), glcdc.Format.rgb565.bytesPerPixel());
    try std.testing.expectEqual(@as(u32, 2), glcdc.Format.argb1555.bytesPerPixel());
    try std.testing.expectEqual(@as(u32, 2), glcdc.Format.argb4444.bytesPerPixel());
    try std.testing.expectEqual(@as(u32, 1), glcdc.Format.clut8.bytesPerPixel());
    try std.testing.expectEqual(@as(u32, 1), glcdc.Format.clut4.bytesPerPixel());
    try std.testing.expectEqual(@as(u32, 1), glcdc.Format.clut1.bytesPerPixel());
}

test "a framebuffer base is recognised in each modelled RAM window" {
    try std.testing.expect(glcdc.addressIsRam(0x2200_0000));
    try std.testing.expect(glcdc.addressIsRam(0x6800_0000));
    try std.testing.expect(glcdc.addressIsRam(0x7800_0000));
    try std.testing.expect(!glcdc.addressIsRam(0x2000_0000));
    try std.testing.expect(!glcdc.addressIsRam(0x1FFF_FFFF));
    try std.testing.expect(!glcdc.addressIsRam(0x6C00_0000));
}

test "starting a layer is counted once per rising edge" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = glcdc.Glcdc.init(&domain);
    programLayer(&unit, layer1, fb_base);
    try std.testing.expectEqual(@as(u32, 1), unit.starts);
    unit.write(layer1 + glcdc.off.flmrd, 4, 1);
    try std.testing.expectEqual(@as(u32, 1), unit.starts);
    unit.write(layer1 + glcdc.off.flmrd, 4, 0);
    unit.write(layer1 + glcdc.off.flmrd, 4, 1);
    try std.testing.expectEqual(@as(u32, 2), unit.starts);
}

test "a register the firmware wrote reads back" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = glcdc.Glcdc.init(&domain);
    unit.write(glcdc.win_base + 0x1450, 4, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), unit.read(glcdc.win_base + 0x1450, 4));
}

test "powering the domain back off takes the framebuffer away again" {
    const guard = unlockedGuard();
    var domain = poweredDomain(&guard);
    var unit = glcdc.Glcdc.init(&domain);
    programLayer(&unit, layer1, fb_base);
    try std.testing.expect(unit.framebuffer() != null);
    domain.write(pdctr.Domain.graphics.base(), 1, pdctr.field.pdde);
    try std.testing.expectEqual(@as(?glcdc.Framebuffer, null), unit.framebuffer());
}

test "a halfword store keeps the lanes it does not name" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = glcdc.Glcdc.init(&domain);
    // The whole descriptor word: stride above, reserved below.
    unit.write(layer1 + glcdc.off.flm3, 4, 0xFFFF_1234);
    // A driver setting the stride alone stores a halfword at the high half.
    unit.write(layer1 + glcdc.off.flm3 + 2, 2, 960);
    try std.testing.expectEqual(
        @as(u32, (960 << 16) | 0x1234),
        unit.read(layer1 + glcdc.off.flm3, 4),
    );
}

test "a halfword read answers the half it names, not the low one" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = glcdc.Glcdc.init(&domain);
    unit.write(layer1 + glcdc.off.flm3, 4, (960 << 16) | 0x1234);
    try std.testing.expectEqual(@as(u32, 960), unit.read(layer1 + glcdc.off.flm3 + 2, 2));
    try std.testing.expectEqual(@as(u32, 0x1234), unit.read(layer1 + glcdc.off.flm3, 2));
    try std.testing.expectEqual(@as(u32, 0x34), unit.read(layer1 + glcdc.off.flm3, 1));
    try std.testing.expectEqual(@as(u32, 0x03), unit.read(layer1 + glcdc.off.flm3 + 3, 1));
}

test "a byte store into the format lane leaves the rest of FLM6 standing" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = glcdc.Glcdc.init(&domain);
    unit.write(layer1 + glcdc.off.flm6, 4, 0x0000_00AB);
    // FORMAT sits at [30:28], so a driver setting it alone stores the top byte.
    const format = @as(u32, @backingInt(glcdc.Format.rgb565)) << 4;
    unit.write(layer1 + glcdc.off.flm6 + 3, 1, format);
    try std.testing.expectEqual(
        @as(u32, (format << 24) | 0xAB),
        unit.read(layer1 + glcdc.off.flm6, 4),
    );
}

test "a layer programmed with narrow stores still decodes" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = glcdc.Glcdc.init(&domain);
    // Every field written the narrow way a driver with an 8- or 16-bit
    // register accessor would write it.
    unit.write(layer1 + glcdc.off.flm2, 2, fb_base & 0xFFFF);
    unit.write(layer1 + glcdc.off.flm2 + 2, 2, fb_base >> 16);
    unit.write(layer1 + glcdc.off.flm3 + 2, 2, 960);
    unit.write(layer1 + glcdc.off.flm5 + 2, 2, 271);
    unit.write(layer1 + glcdc.off.flm6 + 3, 1, @as(u32, @backingInt(glcdc.Format.rgb565)) << 4);
    unit.write(layer1 + glcdc.off.flmrd, 1, 1);
    unit.write(bg_en, 1, 1);
    const frame = unit.framebuffer() orelse return error.NoFramebuffer;
    try std.testing.expectEqual(fb_base, frame.base);
    try std.testing.expectEqual(@as(u32, 480), frame.width);
    try std.testing.expectEqual(@as(u32, 272), frame.height);
    try std.testing.expectEqual(glcdc.Format.rgb565, frame.format);
    try std.testing.expect(frame.enabled);
}

test "a narrow store does not start a layer twice" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = glcdc.Glcdc.init(&domain);
    unit.write(layer1 + glcdc.off.flmrd, 1, 1);
    unit.write(layer1 + glcdc.off.flmrd + 1, 1, 0);
    unit.write(layer1 + glcdc.off.flmrd, 1, 1);
    try std.testing.expectEqual(@as(u32, 1), unit.starts);
}

test "a CLUT entry answers a narrow read from the lane it names" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = glcdc.Glcdc.init(&domain);
    // GR2_CLUT0 entry 0: the third of the four 1 KiB planes the window opens with.
    const slot = glcdc.win_base + 0x800;
    unit.write(slot, 4, 0xAABB_CCDD);
    try std.testing.expectEqual(@as(u32, 0xAABB_CCDD), unit.read(slot, 4));
    try std.testing.expectEqual(@as(u32, 0xAABB), unit.read(slot + 2, 2));
    try std.testing.expectEqual(@as(u32, 0xDD), unit.read(slot, 1));
}

test "BG_EN.VEN reads back clear so the driver's vblank poll finishes" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = glcdc.Glcdc.init(&domain);
    // ra8_glcdc_bg_color_set: set VEN on top of the running output stage,
    // then poll it back down. dev kept the bit and burned all 0x40000
    // iterations before returning a timeout.
    unit.write(bg_en, 4, 1);
    unit.write(bg_en, 4, 0x101);
    try std.testing.expectEqual(@as(u32, 0), unit.read(bg_en, 4) & 0x100);
    try std.testing.expectEqual(@as(u32, 1), unit.updates());
}

test "the output stage stays enabled through the store that spends the VEN" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = glcdc.Glcdc.init(&domain);
    unit.write(bg_en, 4, 0x101);
    try std.testing.expectEqual(@as(u32, 1), unit.read(bg_en, 4));
    try std.testing.expect(unit.outputEnabled());
}

test "each layer's VEN auto-clears too" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = glcdc.Glcdc.init(&domain);
    unit.write(glcdc.win_base + 0x1100, 4, 1);
    unit.write(glcdc.win_base + 0x1200, 4, 1);
    try std.testing.expectEqual(@as(u32, 0), unit.read(glcdc.win_base + 0x1100, 4));
    try std.testing.expectEqual(@as(u32, 0), unit.read(glcdc.win_base + 0x1200, 4));
    try std.testing.expectEqual(@as(u32, 2), unit.updates());
}

test "a narrow store that names the VEN lane spends it" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = glcdc.Glcdc.init(&domain);
    // BG_EN.VEN is bit 8, so byte 1 is the lane that carries it.
    unit.write(bg_en + 1, 1, 1);
    try std.testing.expectEqual(@as(u32, 0), unit.read(bg_en, 4));
    try std.testing.expectEqual(@as(u32, 1), unit.updates());
}

test "a store with no VEN asks for no update" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = glcdc.Glcdc.init(&domain);
    unit.write(bg_en, 4, 1);
    unit.write(glcdc.win_base + 0x1100, 4, 0);
    try std.testing.expectEqual(@as(u32, 0), unit.updates());
}

test "a layer descriptor still decodes after its VEN went by" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = glcdc.Glcdc.init(&domain);
    unit.write(layer1 + glcdc.off.flm2, 4, fb_base);
    unit.write(layer1 + glcdc.off.flm3, 4, 960 << 16);
    unit.write(layer1 + glcdc.off.flm5, 4, 271 << 16);
    unit.write(layer1 + glcdc.off.flm6, 4, @as(u32, @backingInt(glcdc.Format.rgb565)) << 28);
    unit.write(layer1 + glcdc.off.flmrd, 4, 1);
    unit.write(glcdc.win_base + 0x1100, 4, 1);
    unit.write(bg_en, 4, 0x101);
    const frame = unit.framebuffer() orelse return error.NoFramebuffer;
    try std.testing.expectEqual(fb_base, frame.base);
    try std.testing.expectEqual(@as(u32, 480), frame.width);
    try std.testing.expect(frame.enabled);
}
