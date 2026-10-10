//! Covers src/chip/periph/adc/adc_tsn_cal.zig: the TSN calibration words are
//! mapped and seeded, a page an image mapped is left alone, and the seed
//! converts the modelled die code to a plausible temperature.
const std = @import("std");
const ra8 = @import("ra8");

const store_memory = @import("../store_memory.zig");
const tsn_cal = ra8.chip.periph.adc.tsn_cal;
const adc_scan = ra8.chip.periph.adc_scan;

test "map seeds both calibration words where adc_diag_tsn_demo stopped" {
    const core = try store_memory.open();
    defer store_memory.close(core);

    try std.testing.expect(try tsn_cal.map(core));
    try std.testing.expectEqual(tsn_cal.code.high, try core.readWord(0x02C1_EDA0));
    try std.testing.expectEqual(tsn_cal.code.low, try core.readWord(0x02C1_EDA4));
}

test "a page something already mapped keeps its bytes" {
    const core = try store_memory.open();
    defer store_memory.close(core);

    try core.map(tsn_cal.addr.page_base, tsn_cal.page);
    try core.writeWord(tsn_cal.addr.tscdr, 0x0000_0ABC);
    try std.testing.expect(!try tsn_cal.map(core));
    try std.testing.expectEqual(@as(u32, 0x0000_0ABC), try core.readWord(tsn_cal.addr.tscdr));
}

/// The firmware's two-point conversion (ra8_tsn_convert_to_milli_c), with
/// its constants: AVCC 3.3 V in uV, a 4096-code full scale, 125 / -40 degC.
fn milliC(raw: u32, hi: u32, lo: u32) i64 {
    const avcc: i64 = 3_300_000;
    const full: i64 = 4096;
    const v1 = @divTrunc(avcc * hi, full);
    const v2 = @divTrunc(avcc * lo, full);
    const vs = @divTrunc(avcc * raw, full);
    const t1: i64 = 125_000;
    const t2: i64 = -40_000;
    return @divTrunc((vs - v1) * (t1 - t2), v1 - v2) + t1;
}

test "the seed turns the modelled die code into 26 degC" {
    try std.testing.expect(tsn_cal.code.high & 0xFFF == tsn_cal.code.high);
    try std.testing.expect(tsn_cal.code.low & 0xFFF == tsn_cal.code.low);
    try std.testing.expect(tsn_cal.code.high != tsn_cal.code.low);
    const t = milliC(adc_scan.temperature_code, tsn_cal.code.high, tsn_cal.code.low);
    try std.testing.expectEqual(@as(i64, 26_000), t);
}
