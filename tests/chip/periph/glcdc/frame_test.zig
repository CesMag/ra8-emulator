//! Covers src/chip/periph/glcdc/frame.zig: the RAM a framebuffer may live in,
//! and where the window it starts in runs out.
const std = @import("std");
const ra8 = @import("ra8");

const frame = ra8.chip.periph.glcdc_frame;
const memmap = ra8.chip.core.memmap;

test "a framebuffer lives in the RAM a bus initiator can reach" {
    try std.testing.expect(frame.addressIsRam(memmap.sram_base));
    try std.testing.expect(frame.addressIsRam(memmap.sram_end - 4));
    try std.testing.expect(frame.addressIsRam(memmap.sdram_base));
    try std.testing.expect(frame.addressIsRam(memmap.ns_sdram_base));
}

test "the controller fetches over the fabric, so the core's TCM is not RAM to it" {
    try std.testing.expect(!frame.addressIsRam(memmap.dtcm_base));
    try std.testing.expect(!frame.addressIsRam(memmap.dtcm_end - 4));
}

test "a base past the end of the SRAM is not a framebuffer" {
    // The private table this file used to carry ran the SRAM window a
    // megabyte past its end, so this address decoded as a framebuffer and
    // then faulted on the first line it tried to read.
    try std.testing.expect(!frame.addressIsRam(memmap.sram_end));
    try std.testing.expect(!frame.addressIsRam(memmap.sram_end + 0x8_0000));
}

test "nothing outside RAM is a framebuffer" {
    try std.testing.expect(!frame.addressIsRam(0x1FFF_FFFF));
    try std.testing.expect(!frame.addressIsRam(memmap.sdram_end));
    try std.testing.expect(!frame.addressIsRam(memmap.ns_sdram_end));
    try std.testing.expect(!frame.addressIsRam(0x4000_0000));
}

test "the window end is the end of the window the base sits in" {
    try std.testing.expectEqual(memmap.sram_end, frame.windowEnd(memmap.sram_base).?);
    try std.testing.expectEqual(memmap.sdram_end, frame.windowEnd(memmap.sdram_base + 0x1000).?);
    try std.testing.expectEqual(memmap.ns_sdram_end, frame.windowEnd(memmap.ns_sdram_base).?);
    try std.testing.expect(frame.windowEnd(memmap.dtcm_base) == null);
}

test "a shape carries the end of its own window" {
    const shape = frame.shapeOf(.{
        .base = memmap.ns_sdram_base,
        .width = 16,
        .height = 8,
        .stride = 64,
        .format = .argb8888,
        .layer = 1,
        .enabled = true,
    });
    try std.testing.expectEqual(memmap.ns_sdram_base, shape.base);
    try std.testing.expectEqual(memmap.ns_sdram_end, shape.window_end.?);
}
