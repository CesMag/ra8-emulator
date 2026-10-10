//! Covers src/chip/periph/adc/adc.zig.
const std = @import("std");
const ra8 = @import("ra8");
const adc = ra8.chip.periph.adc;
const scan = ra8.chip.periph.adc.scan;

fn unit() adc.Adc {
    return adc.Adc.init();
}

/// Enrol a slot the way a driver does: the source and the group in ADCHCRn,
/// the data format in that slot's ADDOPCRCn.
fn enrol(block: *adc.Adc, slot: usize, group: u32, source: u32, format: scan.Format) void {
    const word = (source << scan.chcr.cnvcs_shift) | group;
    block.write(adc.slotAddress(slot), 4, word);
    const code: u32 = @backingInt(format);
    block.write(adc.formatAddress(slot), 4, code << scan.opcrc.adprc_shift);
}

fn enableGroup(block: *adc.Adc, group: u5) void {
    const current = block.read(adc.win_base + adc.off.adsger, 4);
    block.write(adc.win_base + adc.off.adsger, 4, current | (@as(u32, 1) << group));
}

fn start(block: *adc.Adc, group: usize) void {
    block.write(adc.startAddress(group), 4, adc.field.adst);
}

test "a fresh converter is quiet and its results are empty" {
    var block = unit();
    try std.testing.expect(block.quiet());
    try std.testing.expectEqual(@as(u32, 0), block.read(adc.resultAddress(0), 4));
    try std.testing.expectEqual(@as(u32, 0), block.read(adc.win_base + adc.off.adsr, 4));
}

test "a control register reads back what was written" {
    var block = unit();
    block.write(adc.slotAddress(3), 4, 0x0000_0402);
    try std.testing.expectEqual(@as(u32, 0x0000_0402), block.read(adc.slotAddress(3), 4));
}

test "an enabled group converts its enrolled channel" {
    var block = unit();
    enrol(&block, 2, 1, 2, .bits16);
    enableGroup(&block, 1);
    start(&block, 1);
    try std.testing.expectEqual(@as(u32, 0x8000), block.read(adc.resultAddress(2), 4));
    try std.testing.expectEqual(@as(u32, 1), block.scans);
    try std.testing.expectEqual(@as(u32, 1), block.converted);
    try std.testing.expectEqual(@as(u16, 0x8000), block.last_code);
}

test "a start on a group ADSGER never enabled is refused" {
    var block = unit();
    enrol(&block, 0, 3, 0, .bits12);
    start(&block, 3);
    try std.testing.expectEqual(@as(u32, 0), block.read(adc.resultAddress(0), 4));
    try std.testing.expectEqual(@as(u32, 1), block.refused_disabled);
    try std.testing.expectEqual(@as(u32, 0), block.scans);
}

test "the refused start leaves no event behind" {
    var block = unit();
    enrol(&block, 0, 3, 0, .bits12);
    start(&block, 3);
    try std.testing.expectEqual(@as(usize, 0), block.dueEvents().len);
}

test "a completed scan offers the scan end event once" {
    var block = unit();
    enrol(&block, 0, 3, 0, .bits12);
    enableGroup(&block, 3);
    // ADINTCR gates the event (src/chip/periph/adc/intr.zig); a scan run with it
    // clear converts and raises nothing, which is its own test next door.
    block.write(adc.win_base + adc.off.adintcr, 4, 0x0000_0008);
    start(&block, 3);
    const due = block.dueEvents();
    try std.testing.expectEqual(@as(usize, 1), due.len);
    try std.testing.expectEqual(adc.event.scan_end, due.constSlice()[0]);
    try std.testing.expectEqual(@as(usize, 0), block.dueEvents().len);
}

test "the result follows the slot's data format" {
    var block = unit();
    enrol(&block, 0, 3, 0, .bits10);
    enrol(&block, 1, 3, 1, .bits14);
    enableGroup(&block, 3);
    start(&block, 3);
    try std.testing.expectEqual(@as(u32, 0x0200), block.read(adc.resultAddress(0), 4));
    try std.testing.expectEqual(@as(u32, 0x2000), block.read(adc.resultAddress(1), 4));
    try std.testing.expectEqual(@as(u32, 2), block.converted);
}

test "only the started group converts" {
    var block = unit();
    enrol(&block, 0, 3, 0, .bits12);
    enrol(&block, 1, 4, 1, .bits12);
    enableGroup(&block, 4);
    start(&block, 4);
    try std.testing.expectEqual(@as(u32, 0), block.read(adc.resultAddress(0), 4));
    try std.testing.expectEqual(@as(u32, 0x0800), block.read(adc.resultAddress(1), 4));
}

test "an on chip source reports through ADEXDR, not ADDR" {
    var block = unit();
    enrol(&block, 0, 3, scan.ext.temperature, .bits12);
    enableGroup(&block, 3);
    start(&block, 3);
    try std.testing.expectEqual(@as(u32, 0), block.read(adc.resultAddress(0), 4));
    try std.testing.expectEqual(
        @as(u32, scan.temperature_code),
        block.read(adc.extResultAddress(4), 4),
    );
}

test "the self diagnosis source takes the group's armed mode" {
    var block = unit();
    enrol(&block, 0, 2, scan.ext.selfdiag, .bits16);
    block.write(adc.diagAddress(2), 4, scan.diag.mode3);
    enableGroup(&block, 2);
    start(&block, 2);
    try std.testing.expectEqual(
        @as(u32, scan.diag.positive_full_scale),
        block.read(adc.extResultAddress(0), 4),
    );
}

test "a store into a result register is refused" {
    var block = unit();
    block.write(adc.resultAddress(5), 4, 0x1234);
    try std.testing.expectEqual(@as(u32, 0), block.read(adc.resultAddress(5), 4));
    try std.testing.expectEqual(@as(u32, 1), block.faked);
}

test "a store into an extended result register is refused" {
    var block = unit();
    block.write(adc.extResultAddress(1), 4, 0x1234);
    try std.testing.expectEqual(@as(u32, 0), block.read(adc.extResultAddress(1), 4));
    try std.testing.expectEqual(@as(u32, 1), block.faked);
}

test "a store into ADSR is refused" {
    var block = unit();
    block.write(adc.win_base + adc.off.adsr, 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), block.read(adc.win_base + adc.off.adsr, 4));
    try std.testing.expectEqual(@as(u32, 1), block.faked);
}

test "ADACT0 reads idle so a busy poll completes" {
    var block = unit();
    enrol(&block, 0, 3, 0, .bits12);
    enableGroup(&block, 3);
    start(&block, 3);
    const status = block.read(adc.win_base + adc.off.adsr, 4);
    try std.testing.expectEqual(@as(u32, 0), status & adc.field.adact0);
}

test "the start bit is spent by the time the store returns" {
    var block = unit();
    enrol(&block, 0, 3, 0, .bits12);
    enableGroup(&block, 3);
    start(&block, 3);
    try std.testing.expectEqual(@as(u32, 0), block.read(adc.startAddress(3), 4));
}

test "a refused start spends the bit too, and keeps the rest of the word" {
    var block = unit();
    block.write(adc.startAddress(3), 4, 0x0000_00FF);
    try std.testing.expectEqual(@as(u32, 0x0000_00FE), block.read(adc.startAddress(3), 4));
    try std.testing.expectEqual(@as(u32, 1), block.refused_disabled);
}

test "a start register written with ADST clear is just a store" {
    var block = unit();
    enableGroup(&block, 3);
    block.write(adc.startAddress(3), 4, 0x0000_0010);
    try std.testing.expectEqual(@as(u32, 0x0000_0010), block.read(adc.startAddress(3), 4));
    try std.testing.expectEqual(@as(u32, 0), block.scans);
}

test "a byte store to ADST leaves the bytes above it alone" {
    var block = unit();
    block.write(adc.startAddress(3), 4, 0xAABB_CC00);
    enableGroup(&block, 3);
    block.write(adc.startAddress(3), 1, adc.field.adst);
    try std.testing.expectEqual(@as(u32, 1), block.scans);
    try std.testing.expectEqual(@as(u32, 0xAABB_CC00), block.read(adc.startAddress(3), 4));
}

test "a halfword store into a slot keeps the bytes above it" {
    var block = unit();
    block.write(adc.slotAddress(0), 4, 0x00AA_0000);
    block.write(adc.slotAddress(0), 2, 0x0503);
    try std.testing.expectEqual(@as(u32, 0x00AA_0503), block.read(adc.slotAddress(0), 4));
    try std.testing.expectEqual(@as(u32, 0x0503), block.read(adc.slotAddress(0), 2));
}

test "a group with nothing enrolled converts nothing and says so" {
    var block = unit();
    enableGroup(&block, 6);
    start(&block, 6);
    try std.testing.expectEqual(@as(u32, 1), block.empty);
    try std.testing.expectEqual(@as(u32, 0), block.converted);
    try std.testing.expectEqual(@as(u32, 1), block.scans);
}

test "a pin channel on the slot with no result register is counted" {
    var block = unit();
    enrol(&block, 23, 5, 3, .bits12);
    enableGroup(&block, 5);
    start(&block, 5);
    try std.testing.expectEqual(@as(u32, 1), block.unbacked);
    try std.testing.expectEqual(@as(u32, 0), block.converted);
}

test "ADSTOPR is a force stop, and keeps the rest of the start word" {
    var block = unit();
    block.write(adc.startAddress(1), 4, 0x0000_00FE);
    block.write(adc.win_base + adc.off.adstopr, 4, 1);
    try std.testing.expectEqual(@as(u32, 0x0000_00FE), block.read(adc.startAddress(1), 4));
    try std.testing.expectEqual(@as(u32, 1), block.stops);
}

test "an access past the window answers zero and changes nothing" {
    var block = unit();
    block.write(adc.win_base + adc.win_span, 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), block.read(adc.win_base + adc.win_span, 4));
    try std.testing.expect(block.quiet());
}

test "the block answers for its own window" {
    var block = unit();
    const descriptor = block.block();
    try std.testing.expectEqual(adc.win_base, descriptor.base);
    try std.testing.expectEqual(adc.win_span, descriptor.size);
    try std.testing.expect(descriptor.covers(adc.resultAddress(0)));
    try std.testing.expect(!descriptor.covers(adc.win_base + adc.win_span));
}

test "a run that only converted is still reported" {
    var block = unit();
    enrol(&block, 0, 3, 0, .bits12);
    enableGroup(&block, 3);
    start(&block, 3);
    try std.testing.expect(!block.quiet());
}

test "group zero takes every unprogrammed slot with it" {
    var block = unit();
    enableGroup(&block, 0);
    start(&block, 0);
    // Twenty-three slots have an ADDR behind them; the twenty-fourth does
    // not, which is why it is counted rather than converted.
    try std.testing.expectEqual(@as(u32, 23), block.converted);
    try std.testing.expectEqual(@as(u32, 1), block.unbacked);
    try std.testing.expectEqual(@as(u32, 0), block.empty);
}
