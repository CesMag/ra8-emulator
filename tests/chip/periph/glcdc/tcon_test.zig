//! TCON: the panel timing, and which pin carries which sync signal.
const std = @import("std");
const ra8 = @import("ra8");
const tcon = ra8.chip.periph.glcdc.tcon;

/// The timing the in-tree driver programs for the ER-TFT070-6 panel, the
/// numbers internal_program_tcon writes out of the board's panel table.
const panel = struct {
    const h_active: u32 = 1024;
    const h_back: u32 = 160;
    const h_sync: u32 = 20;
    const v_active: u32 = 600;
    const v_back: u32 = 23;
    const v_sync: u32 = 3;
};

fn programmed() tcon.Tcon {
    var unit = tcon.Tcon{};
    _ = unit.latch(tcon.off.tim, 0);
    _ = unit.latch(tcon.off.stva1, panel.v_sync);
    _ = unit.latch(tcon.off.stva2, @backingInt(tcon.Signal.stva) | tcon.field.invert);
    _ = unit.latch(tcon.off.stha1, panel.h_sync);
    _ = unit.latch(tcon.off.stha2, @backingInt(tcon.Signal.de));
    _ = unit.latch(tcon.off.stvb1, (panel.v_sync + panel.v_back) << tcon.field.start_shift | panel.v_active);
    _ = unit.latch(tcon.off.stvb2, @backingInt(tcon.Signal.stha) | tcon.field.invert);
    _ = unit.latch(tcon.off.sthb1, (panel.h_sync + panel.h_back) << tcon.field.start_shift | panel.h_active);
    _ = unit.latch(tcon.off.sthb2, 0);
    _ = unit.latch(tcon.off.de, 0);
    return unit;
}

test "a block nobody wrote to is quiet and has no timing" {
    const unit = tcon.Tcon{};
    try std.testing.expect(unit.quiet());
    try std.testing.expect(unit.timing() == null);
}

test "the block claims its own offsets and nothing else" {
    try std.testing.expect(tcon.owns(tcon.off.tim));
    try std.testing.expect(tcon.owns(tcon.off.de));
    try std.testing.expect(!tcon.owns(tcon.off.base - 4));
    try std.testing.expect(!tcon.owns(tcon.off.base + tcon.off.span));
}

test "a write outside the block is declined" {
    var unit = tcon.Tcon{};
    try std.testing.expect(!unit.latch(0x1000, 1));
    try std.testing.expect(unit.quiet());
}

test "the driver's own writes decode to the panel it programmed" {
    const unit = programmed();
    const found = unit.timing().?;
    try std.testing.expectEqual(panel.h_active, found.h_active);
    try std.testing.expectEqual(panel.v_active, found.v_active);
    try std.testing.expectEqual(panel.h_sync, found.h_sync);
    try std.testing.expectEqual(panel.v_sync, found.v_sync);
    try std.testing.expectEqual(panel.h_back, found.h_back);
    try std.testing.expectEqual(panel.v_back, found.v_back);
}

test "the active area starts after the pulse and the back porch" {
    const found = programmed().timing().?;
    try std.testing.expectEqual(panel.h_sync + panel.h_back, found.hStart());
    try std.testing.expectEqual(panel.v_sync + panel.v_back, found.vStart());
}

test "one active-area register alone is not a panel" {
    var unit = tcon.Tcon{};
    _ = unit.latch(tcon.off.sthb1, 180 << tcon.field.start_shift | panel.h_active);
    try std.testing.expect(unit.timing() == null);
    _ = unit.latch(tcon.off.stvb1, 26 << tcon.field.start_shift | panel.v_active);
    try std.testing.expect(unit.timing() != null);
}

test "a start inside its own sync pulse reports no back porch instead of wrapping" {
    var unit = tcon.Tcon{};
    _ = unit.latch(tcon.off.stha1, 40);
    _ = unit.latch(tcon.off.sthb1, 20 << tcon.field.start_shift | 320);
    _ = unit.latch(tcon.off.stvb1, 10 << tcon.field.start_shift | 240);
    try std.testing.expectEqual(@as(u32, 0), unit.timing().?.h_back);
}

test "the pulse width keeps only its own field" {
    var unit = tcon.Tcon{};
    _ = unit.latch(tcon.off.stva1, 0xFFFF_F003);
    try std.testing.expectEqual(@as(u32, 3), unit.v_sync);
}

test "VSYNC leaves on TCON0 inverted, DE on TCON2 upright" {
    const unit = programmed();
    try std.testing.expectEqual(@as(?usize, 0), unit.pinFor(.stva));
    try std.testing.expect(unit.pin[0].inverted);
    try std.testing.expectEqual(@as(?usize, 2), unit.pinFor(.de));
    try std.testing.expect(!unit.pin[2].inverted);
}

test "HSYNC reaches the glass through STVB's pin, not STHA's" {
    const unit = programmed();
    try std.testing.expectEqual(@as(?usize, 1), unit.pinFor(.stha));
    try std.testing.expect(unit.pin[1].inverted);
}

test "an unrouted signal has no pin" {
    const unit = programmed();
    try std.testing.expect(unit.pinFor(.stvb) == null);
}

test "a pin nobody wrote is not claimed by the signal it defaults to" {
    var unit = tcon.Tcon{};
    _ = unit.latch(tcon.off.tim, 0);
    try std.testing.expect(unit.pinFor(.stva) == null);
}

test "a reserved SEL code reads back as reserved rather than a named signal" {
    var unit = tcon.Tcon{};
    _ = unit.latch(tcon.off.stva2, 5);
    try std.testing.expectEqualStrings("reserved", unit.pin[0].signal.name());
}

test "a layer inside the active area fits, one past it does not" {
    const unit = programmed();
    try std.testing.expect(unit.contains(panel.h_active, panel.v_active));
    try std.testing.expect(!unit.contains(panel.h_active + 1, panel.v_active));
    try std.testing.expect(!unit.contains(panel.h_active, panel.v_active + 1));
}

test "an unprogrammed block clips nothing" {
    const unit = tcon.Tcon{};
    try std.testing.expect(unit.contains(4096, 4096));
}

test "TIM and DE are kept, so a non-default value is visible" {
    var unit = tcon.Tcon{};
    _ = unit.latch(tcon.off.tim, 0x0000_0201);
    _ = unit.latch(tcon.off.de, 0x1);
    try std.testing.expectEqual(@as(u32, 0x0000_0201), unit.tim);
    try std.testing.expectEqual(@as(u32, 1), unit.de);
}

test "every write into the block is counted" {
    const unit = programmed();
    try std.testing.expectEqual(@as(u32, 10), unit.writes);
    try std.testing.expect(!unit.quiet());
}
