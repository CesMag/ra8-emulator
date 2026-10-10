//! Covers src/chip/periph/drw/cache.zig: where a painted pixel is while the
//! framebuffer cache is on, what a flush moves, what a destination read is
//! answered with, and the texture cache's enable and flush pulses.
const std = @import("std");
const ra8 = @import("ra8");

const cache = ra8.chip.periph.drw_cache;
const store_memory = @import("../store_memory.zig");
const Guest = store_memory.Guest;

/// An SRAM address a framebuffer can live at.
const fb_base: u32 = 0x2200_0000;

fn wordAt(memory: Guest, at: u32) !u32 {
    return memory.readWord(at);
}

test "a cache nobody enabled takes nothing, so the caller writes memory itself" {
    var unit = cache.Framebuffer{};
    try std.testing.expect(!unit.store(null, fb_base, 4, 0xFF00_FF00));
    try std.testing.expect(!unit.dirty());
    try std.testing.expectEqual(@as(u64, 0), unit.held);
    try std.testing.expect(unit.quiet());
}

test "CENABLEFX puts the pixel in the cache and not in memory" {
    const memory = try store_memory.open();
    defer store_memory.close(memory);
    try memory.writeWord(fb_base, 0);

    var unit = cache.Framebuffer{};
    unit.control(memory, cache.bits.enable_fb);
    try std.testing.expect(unit.store(memory, fb_base, 4, 0xFF00_FF00));
    try std.testing.expect(unit.dirty());
    try std.testing.expectEqual(@as(u32, 0), try wordAt(memory, fb_base));
}

test "CFLUSHFX is what puts it in memory" {
    const memory = try store_memory.open();
    defer store_memory.close(memory);
    try memory.writeWord(fb_base, 0);

    var unit = cache.Framebuffer{};
    unit.control(memory, cache.bits.enable_fb);
    _ = unit.store(memory, fb_base, 4, 0xFF00_FF00);
    unit.control(memory, cache.bits.enable_fb | cache.bits.flush_fb);
    try std.testing.expect(!unit.dirty());
    try std.testing.expectEqual(@as(u32, 0xFF00_FF00), try wordAt(memory, fb_base));
    try std.testing.expectEqual(@as(u64, 1), unit.written_back);
}

test "the flush pulse acts on what is held now, before the new enable state" {
    const memory = try store_memory.open();
    defer store_memory.close(memory);
    try memory.writeWord(fb_base, 0);

    var unit = cache.Framebuffer{};
    unit.control(memory, cache.bits.enable_fb);
    _ = unit.store(memory, fb_base, 4, 0x1234_5678);
    // The HAL's own word: enables plus the framebuffer flush in one write.
    unit.control(memory, cache.bits.enable_fb | cache.bits.enable_tx | cache.bits.flush_fb);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), try wordAt(memory, fb_base));
    try std.testing.expect(unit.enabled);
}

test "a second write to the same pixel replaces the held one" {
    const memory = try store_memory.open();
    defer store_memory.close(memory);

    var unit = cache.Framebuffer{};
    unit.control(memory, cache.bits.enable_fb);
    _ = unit.store(memory, fb_base, 4, 0x1111_1111);
    _ = unit.store(memory, fb_base, 4, 0x2222_2222);
    try std.testing.expectEqual(@as(usize, 1), unit.used);
    unit.flush(memory);
    try std.testing.expectEqual(@as(u32, 0x2222_2222), try wordAt(memory, fb_base));
    try std.testing.expectEqual(@as(u64, 1), unit.written_back);
}

test "a destination read is answered from the cache, not from the stale word" {
    const memory = try store_memory.open();
    defer store_memory.close(memory);
    try memory.writeWord(fb_base, 0xDEAD_BEEF);

    var unit = cache.Framebuffer{};
    unit.control(memory, cache.bits.enable_fb);
    _ = unit.store(memory, fb_base, 4, 0xFF00_0000);
    try std.testing.expectEqual(@as(u32, 0xFF00_0000), unit.load(fb_base).?);
    try std.testing.expectEqual(@as(u64, 1), unit.forwarded);
    try std.testing.expect(unit.load(fb_base + 4) == null);
}

test "a full table writes the oldest pixel back to make room" {
    const memory = try store_memory.open();
    defer store_memory.close(memory);

    var unit = cache.Framebuffer{};
    unit.control(memory, cache.bits.enable_fb);
    var index: u32 = 0;
    while (index <= cache.limits.cells) : (index += 1) {
        _ = unit.store(memory, fb_base + index * 4, 4, 0xA000_0000 | index);
    }
    try std.testing.expectEqual(@as(u64, 1), unit.evicted);
    try std.testing.expectEqual(cache.limits.cells, unit.used);
    // The evicted one is the first written, and it is in memory already.
    try std.testing.expectEqual(@as(u32, 0xA000_0000), try wordAt(memory, fb_base));
    try std.testing.expect(unit.load(fb_base) == null);
}

test "switching the cache off writes back what it was holding" {
    const memory = try store_memory.open();
    defer store_memory.close(memory);
    try memory.writeWord(fb_base, 0);

    var unit = cache.Framebuffer{};
    unit.control(memory, cache.bits.enable_fb);
    _ = unit.store(memory, fb_base, 4, 0x0000_00FF);
    unit.control(memory, 0);
    try std.testing.expectEqual(@as(u32, 1), unit.disabled_dirty);
    try std.testing.expectEqual(@as(u32, 0x0000_00FF), try wordAt(memory, fb_base));
    try std.testing.expect(!unit.enabled);
}

test "a pixel narrower than a word writes back only its own bytes" {
    const memory = try store_memory.open();
    defer store_memory.close(memory);
    try memory.writeWord(fb_base, 0xFFFF_FFFF);

    var unit = cache.Framebuffer{};
    unit.control(memory, cache.bits.enable_fb);
    _ = unit.store(memory, fb_base, 2, 0x1234);
    unit.flush(memory);
    try std.testing.expectEqual(@as(u32, 0xFFFF_1234), try wordAt(memory, fb_base));
}

test "a write-back with nowhere to go is counted, not dropped silently" {
    var unit = cache.Framebuffer{};
    unit.control(null, cache.bits.enable_fb);
    _ = unit.store(null, fb_base, 4, 0xFF00_FF00);
    unit.flush(null);
    try std.testing.expectEqual(@as(u32, 1), unit.faults);
    try std.testing.expectEqual(@as(u64, 0), unit.written_back);
    try std.testing.expect(!unit.quiet());
}

test "a write-back the memory refuses is a fault, not a stored pixel" {
    const memory = try store_memory.open();
    defer store_memory.close(memory);

    var unit = cache.Framebuffer{};
    unit.control(memory, cache.bits.enable_fb);
    // Nothing is mapped up here, so the write-back has nowhere to land.
    _ = unit.store(memory, 0xF000_0000, 4, 0xFF00_FF00);
    unit.flush(memory);
    try std.testing.expectEqual(@as(u32, 1), unit.faults);
    try std.testing.expectEqual(@as(u64, 0), unit.written_back);
}

test "the flush count is the pulses, held or not" {
    var unit = cache.Framebuffer{};
    unit.control(null, cache.bits.enable_fb | cache.bits.flush_fb);
    unit.control(null, cache.bits.enable_fb | cache.bits.flush_fb);
    try std.testing.expectEqual(@as(u32, 2), unit.flushes);
    try std.testing.expectEqual(@as(u32, 0), unit.faults);
}

test "the texture cache carries its enable and counts its flush pulses" {
    var unit = cache.Texture{};
    try std.testing.expect(!unit.enabled);
    unit.control(cache.bits.enable_tx);
    try std.testing.expect(unit.enabled);
    unit.control(cache.bits.enable_tx | cache.bits.flush_tx);
    try std.testing.expectEqual(@as(u32, 1), unit.flushes);
    // The HAL's per-blit pulse: flush with neither enable bit set.
    unit.control(cache.bits.flush_tx);
    try std.testing.expectEqual(@as(u32, 2), unit.flushes);
    try std.testing.expect(!unit.enabled);
}

test "an enable write on its own is not a flush" {
    const memory = try store_memory.open();
    defer store_memory.close(memory);
    try memory.writeWord(fb_base, 0);

    var unit = cache.Framebuffer{};
    unit.control(memory, cache.bits.enable_fb);
    _ = unit.store(memory, fb_base, 4, 0x00FF_00FF);
    unit.control(memory, cache.bits.enable_fb);
    try std.testing.expectEqual(@as(u32, 0), unit.flushes);
    try std.testing.expect(unit.dirty());
    try std.testing.expectEqual(@as(u32, 0), try wordAt(memory, fb_base));
}
