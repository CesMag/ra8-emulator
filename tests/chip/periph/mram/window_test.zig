//! Covers src/chip/periph/mram/window.zig: the option window is mapped,
//! reads erased, and a landed program can be read back.
const std = @import("std");
const ra8 = @import("ra8");

const store_memory = @import("../store_memory.zig");
const mram = ra8.chip.periph.mram;
const option_window = mram.option_window;

test "the span is page aligned and covers the whole Program window" {
    try std.testing.expectEqual(@as(u32, 0), option_window.span.base % option_window.page);
    try std.testing.expectEqual(@as(u32, 0), option_window.span.end % option_window.page);
    try std.testing.expect(option_window.span.base <= mram.window.lo);
    try std.testing.expect(option_window.span.end > mram.window.hi);
}

test "a mapped window reads erased where ra8_ftl_demo stopped" {
    const core = try store_memory.open();
    defer store_memory.close(core);

    try std.testing.expect(try option_window.map(core) > 0);
    var byte: [1]u8 = undefined;
    try core.read(0x02E0_A400, &byte);
    try std.testing.expectEqual(mram.window.erased, byte[0]);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), try core.readWord(mram.window.hi & ~@as(u32, 3)));
}

test "a window something already mapped is left as it was" {
    const core = try store_memory.open();
    defer store_memory.close(core);

    try core.map(option_window.span.base, option_window.span.size);
    try core.writeWord(mram.window.lo, 0x1234_5678);
    try std.testing.expectEqual(@as(u32, 0), try option_window.map(core));
    try std.testing.expectEqual(@as(u32, 0x1234_5678), try core.readWord(mram.window.lo));
}

test "an image segment in the window loads over an attached window" {
    const core = try store_memory.open();
    defer store_memory.close(core);

    try std.testing.expectEqual(option_window.span.size / option_window.page, try option_window.map(core));
    try std.testing.expect(option_window.claim(core, 0x02E0_7000, option_window.page));
    try core.write(mram.window.lo, &.{ 0x5A, 0xA5 });
    try std.testing.expectEqual(@as(u32, 0xFFFF_A55A), try core.readWord(mram.window.lo));
    try std.testing.expect(!option_window.claim(core, 0x0200_0000, option_window.page));
}

test "attach after an image maps only the pages the image left" {
    const core = try store_memory.open();
    defer store_memory.close(core);

    try std.testing.expect(option_window.claim(core, 0x02E0_7000, option_window.page));
    try core.writeWord(mram.window.lo, 0x1234_5678);
    const pages = option_window.span.size / option_window.page;
    try std.testing.expectEqual(pages - 1, try option_window.map(core));
    try std.testing.expectEqual(@as(u32, 0x1234_5678), try core.readWord(mram.window.lo));
    var byte: [1]u8 = undefined;
    try core.read(0x02E0_A400, &byte);
    try std.testing.expectEqual(mram.window.erased, byte[0]);
}
