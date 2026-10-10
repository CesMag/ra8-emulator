//! Covers src/chip/periph/adc_intr.zig, and the gate it puts on the scan-end
//! event in src/chip/periph/adc.zig.
const std = @import("std");
const ra8 = @import("ra8");
const adc = ra8.chip.periph.adc;
const intr = ra8.chip.periph.adc_intr;
const scan = ra8.chip.periph.adc_scan;

fn unit() adc.Adc {
    return adc.Adc.init();
}

/// Enrol a slot the way a driver does, then enable its group.
fn arm(block: *adc.Adc, slot: usize, group: u5) void {
    const word = (@as(u32, 1) << scan.chcr.cnvcs_shift) | @as(u32, group);
    block.write(adc.slotAddress(slot), 4, word);
    const current = block.read(adc.win_base + adc.off.adsger, 4);
    block.write(adc.win_base + adc.off.adsger, 4, current | (@as(u32, 1) << group));
}

fn start(block: *adc.Adc, group: usize) void {
    block.write(adc.startAddress(group), 4, adc.field.adst);
}

fn enableInterrupt(block: *adc.Adc, value: u32) void {
    block.write(adc.win_base + adc.off.adintcr, 4, value);
}

test "a cleared ADINTCR enables nothing" {
    try std.testing.expect(!intr.enabled(0));
}

test "any set bit is taken as enabled" {
    try std.testing.expect(intr.enabled(1));
    try std.testing.expect(intr.enabled(0x0000_0100));
}

test "a scan with ADINTCR clear converts and raises nothing" {
    var block = unit();
    arm(&block, 0, 1);
    start(&block, 1);

    try std.testing.expectEqual(@as(u32, 1), block.scans);
    try std.testing.expectEqual(@as(u32, 1), block.converted);
    try std.testing.expectEqual(@as(u32, 1), block.masked);
    try std.testing.expectEqual(@as(usize, 0), block.dueEvents().len);
}

test "the same scan raises once the interrupt is enabled" {
    var block = unit();
    arm(&block, 0, 1);
    enableInterrupt(&block, 0x0000_0002);
    start(&block, 1);

    try std.testing.expectEqual(@as(u32, 0), block.masked);
    const due = block.dueEvents();
    try std.testing.expectEqual(@as(usize, 1), due.len);
    try std.testing.expectEqual(adc.event.scan_end, due.get(0));
}

test "the event is offered once and only once" {
    var block = unit();
    arm(&block, 0, 0);
    enableInterrupt(&block, 0x0000_0001);
    start(&block, 0);

    try std.testing.expectEqual(@as(usize, 1), block.dueEvents().len);
    try std.testing.expectEqual(@as(usize, 0), block.dueEvents().len);
}

test "disabling the interrupt again stops the next scan raising" {
    var block = unit();
    arm(&block, 0, 1);
    enableInterrupt(&block, 0x0000_0002);
    start(&block, 1);
    _ = block.dueEvents();

    enableInterrupt(&block, 0);
    start(&block, 1);
    try std.testing.expectEqual(@as(u32, 2), block.scans);
    try std.testing.expectEqual(@as(u32, 1), block.masked);
    try std.testing.expectEqual(@as(usize, 0), block.dueEvents().len);
}

test "a start refused for a disabled group is not counted as masked" {
    var block = unit();
    start(&block, 3);
    try std.testing.expectEqual(@as(u32, 1), block.refused_disabled);
    try std.testing.expectEqual(@as(u32, 0), block.masked);
}

test "ADINTCR reads back what was written" {
    var block = unit();
    enableInterrupt(&block, 0x0000_01FF);
    try std.testing.expectEqual(
        @as(u32, 0x0000_01FF),
        block.read(adc.win_base + adc.off.adintcr, 4),
    );
}
