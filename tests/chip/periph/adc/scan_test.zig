//! Covers src/chip/periph/adc/scan.zig.
const std = @import("std");
const scan = @import("ra8").chip.periph.adc.scan;

test "a slot word decodes into its group and its source" {
    const slot = scan.Slot.decode(0x0000_0503);
    try std.testing.expectEqual(@as(u32, 3), slot.group);
    try std.testing.expectEqual(@as(u32, 5), slot.source);
    try std.testing.expect(!slot.internal());
}

test "a source at or above the extended base is an on-chip one" {
    const slot = scan.Slot.decode(0x0000_6400);
    try std.testing.expect(slot.internal());
    try std.testing.expectEqual(@as(u32, 4), slot.extIndex());
}

test "the source field stops at seven bits" {
    const slot = scan.Slot.decode(0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0x7F), slot.source);
    try std.testing.expectEqual(@as(u32, 0x1F), slot.group);
}

test "each data format reports its own half scale" {
    try std.testing.expectEqual(@as(u16, 0x8000), scan.Format.bits16.midscale());
    try std.testing.expectEqual(@as(u16, 0x2000), scan.Format.bits14.midscale());
    try std.testing.expectEqual(@as(u16, 0x0800), scan.Format.bits12.midscale());
    try std.testing.expectEqual(@as(u16, 0x0200), scan.Format.bits10.midscale());
}

test "ADPRC picks the format out of bits seventeen and sixteen" {
    try std.testing.expectEqual(scan.Format.bits16, scan.format(0x0000_0000));
    try std.testing.expectEqual(scan.Format.bits14, scan.format(0x0001_0000));
    try std.testing.expectEqual(scan.Format.bits12, scan.format(0x0002_0000));
    try std.testing.expectEqual(scan.Format.bits10, scan.format(0x0003_0000));
}

test "the bits around ADPRC do not change the format" {
    try std.testing.expectEqual(scan.Format.bits12, scan.format(0xFFFC_FFFF | 0x0002_0000));
}

test "self diagnosis reports the ideal for the armed mode" {
    try std.testing.expectEqual(scan.diag.zero, scan.selfDiagnosis(scan.diag.mode1));
    try std.testing.expectEqual(scan.diag.negative_full_scale, scan.selfDiagnosis(scan.diag.mode2));
    try std.testing.expectEqual(scan.diag.positive_full_scale, scan.selfDiagnosis(scan.diag.mode3));
}

test "an unarmed or unknown diagnosis mode drives zero" {
    try std.testing.expectEqual(scan.diag.zero, scan.selfDiagnosis(0));
    try std.testing.expectEqual(scan.diag.zero, scan.selfDiagnosis(7));
}

test "only DIAGVAL's three bits pick the mode" {
    try std.testing.expectEqual(scan.diag.positive_full_scale, scan.selfDiagnosis(0xFFFF_FFF6));
}

test "the temperature sensor has its own code" {
    try std.testing.expectEqual(scan.temperature_code, scan.internalValue(scan.ext.temperature, 0));
}

test "the self diagnosis source follows the group's mode" {
    try std.testing.expectEqual(
        scan.diag.negative_full_scale,
        scan.internalValue(scan.ext.selfdiag, scan.diag.mode2),
    );
}

test "any other internal source reports a mid scale sample" {
    try std.testing.expectEqual(scan.sample_code, scan.internalValue(scan.ext.int_vref, 0));
    try std.testing.expectEqual(scan.sample_code, scan.internalValue(0x70, 0));
}
