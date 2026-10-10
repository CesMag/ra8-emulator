//! Covers src/chip/periph/drw/drw.zig: the power gate over the drawing engine, the
//! ORIGIN trigger, the bounding-box scan, the display-list reader and the
//! configurations this model declines rather than guesses at.
const std = @import("std");
const ra8 = @import("ra8");

const drw = ra8.chip.periph.drw;
const blend = ra8.chip.periph.drw_blend;
const dlist = ra8.chip.periph.drw_dlist;
const cache = ra8.chip.periph.drw_cache;
const limit = ra8.chip.periph.drw_limit;
const pdctr = ra8.chip.periph.pdctr;
const prcr = ra8.chip.periph.prcr;
const store_memory = @import("../store_memory.zig");
const Guest = store_memory.Guest;

/// The SDRAM address the graphics examples draw into.
const fb_base: u32 = 0x6800_0000;

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

fn at(offset: u32) u32 {
    return drw.win_base + offset;
}

/// CONTROL2 for a 32-bit replacing fill that keeps its own alpha: BDI so the
/// fill replaces instead of adding, and WRITEALPHA = 01 so the stored alpha
/// is the source's. Both are corrections the driver had to make; leaving
/// either at its reset value is a bench divergence, not a detail.
const opaque_fill = @as(u32, 2) << blend.control2.format_low_shift |
    blend.control2.dst_invert |
    @as(u32, 1) << blend.control2.write_alpha_shift;

/// Program an opaque fill of `width` x `height`, without triggering it.
fn programFill(unit: *drw.Drw, width: u32, height: u32, pitch: u32, color: u32) void {
    unit.write(at(drw.off.control2), 4, opaque_fill);
    unit.write(at(drw.off.color1), 4, color);
    unit.write(at(drw.off.size), 4, width | height << 16);
    unit.write(at(drw.off.pitch), 4, pitch);
}

test "the block is dark until the graphics domain is powered" {
    const guard = unlockedGuard();
    var domain = pdctr.Pdctr.init(&guard, .graphics);
    var unit = drw.Drw.init(&domain);
    try std.testing.expectEqual(@as(u32, 0), unit.read(at(drw.off.control2), 4));
    unit.write(at(drw.off.color1), 4, 0xFF00_FF00);
    try std.testing.expectEqual(@as(u32, 0), unit.color1);
    try std.testing.expectEqual(@as(u32, 1), unit.dark_reads);
    try std.testing.expectEqual(@as(u32, 1), unit.dropped_unpowered);
}

test "issue #247: HWREVISION answers once PDCTRGD.PDDE is cleared" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = drw.Drw.init(&domain);
    try std.testing.expectEqual(drw.hardware_revision, unit.read(at(drw.off.control2), 4));
}

test "STATUS reads idle and every other register reads zero" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = drw.Drw.init(&domain);
    unit.write(at(drw.off.color1), 4, 0xFF00_FF00);
    try std.testing.expectEqual(@as(u32, 0), unit.read(at(drw.off.control), 4));
    try std.testing.expectEqual(@as(u32, 0), unit.read(at(drw.off.color1), 4));
    try std.testing.expectEqual(@as(u32, 0xFF00_FF00), unit.color1);
}

test "the shadow takes the registers this model rasterizes from" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = drw.Drw.init(&domain);
    unit.write(at(drw.off.control), 4, 0x1);
    unit.write(at(drw.off.color2), 4, 0x8000_0000);
    unit.write(at(drw.off.size), 4, 16 | 8 << 16);
    unit.write(at(drw.off.cachectl), 4, cache.bits.enable_fb);
    try std.testing.expectEqual(@as(u32, 0x1), unit.control);
    try std.testing.expectEqual(@as(u32, 0x8000_0000), unit.color2);
    try std.testing.expectEqual(@as(u32, 16), unit.box().width);
    try std.testing.expectEqual(@as(u32, 8), unit.box().height);
    // CACHECTL does not land in the shadow: it drives the caches.
    try std.testing.expect(unit.pixel_cache.enabled);
}

test "an ORIGIN write with nothing programmed is not counted as declined" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = drw.Drw.init(&domain);
    unit.write(at(drw.off.origin), 4, fb_base);
    try std.testing.expectEqual(@as(u32, 0), unit.declined);
    try std.testing.expectEqual(drw.Decline.unprogrammed, unit.last_decline.?);
}

test "a quadratic coupling and a pattern source are declined" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = drw.Drw.init(&domain);
    programFill(&unit, 16, 16, 480, 0xFF00_FF00);

    unit.write(at(drw.off.control), 4, limit.control.quads);
    unit.write(at(drw.off.origin), 4, fb_base);
    try std.testing.expectEqual(drw.Decline.quad, unit.last_decline.?);

    unit.write(at(drw.off.control), 4, 0);
    unit.write(at(drw.off.control2), 4, blend.control2.pattern_enable);
    unit.write(at(drw.off.origin), 4, fb_base);
    try std.testing.expectEqual(drw.Decline.patterned, unit.last_decline.?);

    // A texture source is read for real, so it is declined only while the
    // texture itself is unprogrammed: TEXORIGIN is still zero here.
    unit.write(at(drw.off.control2), 4, blend.control2.texture_enable);
    unit.write(at(drw.off.origin), 4, fb_base);
    try std.testing.expectEqual(drw.Decline.untexturable, unit.last_decline.?);

    try std.testing.expectEqual(@as(u32, 3), unit.declined);
    try std.testing.expectEqual(@as(u32, 0), unit.renders);
}

test "the framebuffer cache is no longer a decline: the render happens and the pixels are held" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = drw.Drw.init(&domain);
    const memory = try store_memory.open();
    defer store_memory.close(memory);
    unit.memory = memory;

    const ram: u32 = 0x2200_0000;
    try memory.writeWord(ram, 0);
    programFill(&unit, 2, 2, 2, 0xFF00_FF00);
    // What the HAL writes ahead of every line and every triangle.
    unit.write(at(drw.off.cachectl), 4, cache.bits.enable_fb | cache.bits.enable_tx | cache.bits.flush_fb);
    unit.write(at(drw.off.origin), 4, ram);

    try std.testing.expectEqual(@as(u32, 0), unit.declined);
    try std.testing.expectEqual(@as(u32, 1), unit.renders);
    try std.testing.expectEqual(@as(u64, 4), unit.pixels);
    // Painted, held, and not in memory until the flush: STATUS says so.
    try std.testing.expect(unit.pixel_cache.dirty());
    try std.testing.expectEqual(@as(u32, 0), try memory.readWord(ram));
    try std.testing.expectEqual(cache.status.cache_dirty, unit.read(at(drw.off.control), 4));

    unit.write(at(drw.off.cachectl), 4, cache.bits.enable_fb | cache.bits.flush_fb);
    try std.testing.expectEqual(@as(u32, 0xFF00_FF00), try memory.readWord(ram));
    try std.testing.expectEqual(@as(u32, 0), unit.read(at(drw.off.control), 4));
}

test "a render with no memory behind it is declined, not silently counted" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = drw.Drw.init(&domain);
    programFill(&unit, 4, 4, 480, 0xFF00_FF00);
    unit.write(at(drw.off.origin), 4, fb_base);
    try std.testing.expectEqual(drw.Decline.unbacked, unit.last_decline.?);
    try std.testing.expectEqual(@as(u32, 0), unit.renders);
}

/// A board's worth of machine for the rasterizing tests: SDRAM backed, the
/// domain powered, the store handed to the block as its framebuffer memory.
const Bench = struct {
    core: Guest,
    guard: prcr.Prcr,
    domain: pdctr.Pdctr,
    unit: drw.Drw,

    fn open(self: *Bench) !void {
        self.core = try store_memory.open();
        self.guard = unlockedGuard();
        self.domain = poweredDomain(&self.guard);
        self.unit = drw.Drw.init(&self.domain);
        self.unit.memory = self.core;
    }

    fn close(self: *Bench) void {
        store_memory.close(self.core);
    }

    fn pixel(self: *Bench, index: u32) !u32 {
        return self.core.readWord(fb_base + index * 4);
    }
};

test "writing ORIGIN scans the bounding box and stores the pixels" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();

    programFill(&bench.unit, 4, 2, 8, 0xFF00_FF00);
    bench.unit.write(at(drw.off.origin), 4, fb_base);

    try std.testing.expectEqual(@as(u32, 1), bench.unit.renders);
    try std.testing.expectEqual(@as(u64, 8), bench.unit.pixels);
    try std.testing.expectEqual(@as(u32, 4), bench.unit.last_width);
    try std.testing.expectEqual(@as(u32, 2), bench.unit.last_height);
    try std.testing.expectEqual(@as(u32, 0xFF00_FF00), try bench.pixel(0));
    try std.testing.expectEqual(@as(u32, 0xFF00_FF00), try bench.pixel(3));
    // Row two starts a PITCH of pixels along, not a width of them.
    try std.testing.expectEqual(@as(u32, 0), try bench.pixel(4));
    try std.testing.expectEqual(@as(u32, 0xFF00_FF00), try bench.pixel(8));
}

test "the box is anchored where ORIGIN points, so a corner stays untouched" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();

    programFill(&bench.unit, 2, 1, 8, 0xFF11_2233);
    bench.unit.write(at(drw.off.origin), 4, fb_base + 8);

    try std.testing.expectEqual(@as(u32, 0), try bench.pixel(0));
    try std.testing.expectEqual(@as(u32, 0xFF11_2233), try bench.pixel(2));
    try std.testing.expectEqual(@as(u32, 0xFF11_2233), try bench.pixel(3));
}

test "the reset blend adds to what is already in the framebuffer" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();

    try bench.core.writeWord(fb_base, 0x0000_0010);
    const argb8888 = @as(u32, 2) << blend.control2.format_low_shift;
    bench.unit.write(at(drw.off.control2), 4, argb8888);
    bench.unit.write(at(drw.off.color1), 4, 0xFF00_FF00);
    bench.unit.write(at(drw.off.size), 4, 1 | 1 << 16);
    bench.unit.write(at(drw.off.pitch), 4, 1);
    bench.unit.write(at(drw.off.origin), 4, fb_base);

    // Alpha comes from COLOR2, which is zero: issue #170 in one read-back.
    try std.testing.expectEqual(@as(u32, 0x0000_FF10), try bench.pixel(0));
}

test "an RGB565 fill stores two bytes per pixel" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();

    const rgb565 = @as(u32, 1) << blend.control2.format_low_shift;
    bench.unit.write(at(drw.off.control2), 4, rgb565 | blend.control2.dst_invert);
    bench.unit.write(at(drw.off.color1), 4, 0xFFFF_0000);
    bench.unit.write(at(drw.off.size), 4, 2 | 1 << 16);
    bench.unit.write(at(drw.off.pitch), 4, 2);
    bench.unit.write(at(drw.off.origin), 4, fb_base);

    try std.testing.expectEqual(@as(u32, 0xF800_F800), try bench.pixel(0));
}

test "a framebuffer base pointing at nothing mapped is counted, not fatal" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();

    programFill(&bench.unit, 2, 1, 8, 0xFF00_FF00);
    bench.unit.write(at(drw.off.origin), 4, 0x3000_0000);

    try std.testing.expectEqual(@as(u32, 1), bench.unit.renders);
    try std.testing.expectEqual(@as(u32, 2), bench.unit.faults);
}

test "a display list programs registers and its ORIGIN entry draws" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();

    const list = fb_base + 0x800;
    const entries = [_]u32{
        dlist.encoding.one_index | drw.off.control2 / 4, opaque_fill,
        dlist.encoding.one_index | drw.off.color1 / 4,   0xFF44_5566,
        dlist.encoding.one_index | drw.off.size / 4,     2 | 1 << 16,
        dlist.encoding.one_index | drw.off.pitch / 4,    2,
        dlist.encoding.one_index | drw.off.origin / 4,   fb_base,
        dlist.encoding.end_of_list,                      0,
    };
    for (entries, 0..) |word, index| try bench.core.writeWord(list + @as(u32, @intCast(index)) * 4, word);
    bench.unit.write(at(drw.off.dliststart), 4, list);

    try std.testing.expectEqual(@as(u32, 1), bench.unit.dlists);
    try std.testing.expectEqual(@as(u32, 1), bench.unit.renders);
    try std.testing.expectEqual(@as(u32, 0xFF44_5566), try bench.pixel(0));
    try std.testing.expectEqual(@as(u32, 0xFF44_5566), try bench.pixel(1));
}

test "an end-of-list wait keeps reading, and a DLISTSTART entry stops" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();

    const list = fb_base + 0x800;
    const wait = dlist.encoding.end_of_list | dlist.encoding.argument_wait << dlist.encoding.argument_shift;
    const entries = [_]u32{
        wait,
        dlist.encoding.one_index | drw.off.color1 / 4,
        0x1122_3344,
        dlist.encoding.one_index | dlist.encoding.dliststart_index,
        dlist.encoding.one_index | drw.off.color2 / 4,
        0x5566_7788,
    };
    for (entries, 0..) |word, index| try bench.core.writeWord(list + @as(u32, @intCast(index)) * 4, word);
    bench.unit.write(at(drw.off.dliststart), 4, list);

    try std.testing.expectEqual(@as(u32, 0x1122_3344), bench.unit.color1);
    try std.testing.expectEqual(@as(u32, 0), bench.unit.color2);
    try std.testing.expectEqual(@as(u32, 0), bench.unit.dlist_stops);
}

test "an unmodelled multi-index tag stops the reader instead of guessing" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();

    const list = fb_base + 0x800;
    try bench.core.writeWord(list, 0x0000_0003);
    try bench.core.writeWord(list + 4, dlist.encoding.one_index | drw.off.color1 / 4);
    bench.unit.write(at(drw.off.dliststart), 4, list);

    try std.testing.expectEqual(@as(u32, 1), bench.unit.dlist_stops);
    try std.testing.expectEqual(@as(u32, 0), bench.unit.color1);
}

test "the block claims its own window on the bus" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = drw.Drw.init(&domain);
    const claim = unit.block();
    try std.testing.expectEqualStrings("DRW", claim.name);
    try std.testing.expectEqual(drw.win_base, claim.base);
    try std.testing.expect(claim.covers(at(drw.off.dliststart)));
    try std.testing.expect(!claim.covers(drw.win_base + drw.win_span));
}

test "a run that never touched the engine has nothing to narrate" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = drw.Drw.init(&domain);
    try std.testing.expect(unit.quiet());
    unit.write(at(drw.off.color1), 4, 1);
    try std.testing.expect(!unit.quiet());
}

test "a narrow store reaches the lanes it names and leaves the rest standing" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = drw.Drw.init(&domain);
    // A halfword into the top of SIZE is the height, not a new box.
    unit.write(at(drw.off.size), 4, 480 | @as(u32, 272) << drw.field.height_shift);
    unit.write(at(drw.off.size + 2), 2, 136);
    try std.testing.expectEqual(@as(u32, 480), unit.box().width);
    try std.testing.expectEqual(@as(u32, 136), unit.box().height);
    // A byte into the top of COLOR1 is the alpha, not a new colour.
    unit.write(at(drw.off.color1), 4, 0x0012_3456);
    unit.write(at(drw.off.color1 + 3), 1, 0xFF);
    try std.testing.expectEqual(@as(u32, 0xFF12_3456), unit.color1);
    // A pitch laid down in two halfword stores keeps both halves.
    unit.write(at(drw.off.pitch), 2, 0x0480);
    unit.write(at(drw.off.pitch + 2), 2, 0x0001);
    try std.testing.expectEqual(@as(u32, 0x0001_0480), unit.pitch);
}

test "a narrow store into a limiter keeps the lanes it does not name" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = drw.Drw.init(&domain);
    unit.write(at(limit.off.start), 4, 0x1234_5678);
    unit.write(at(limit.off.start), 2, 0xABCD);
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x1234_ABCD))), unit.limits.edges[0].start);
}

test "a halfword read of HWREVISION answers the half it asked for" {
    const guard = unlockedGuard();
    const domain = poweredDomain(&guard);
    var unit = drw.Drw.init(&domain);
    try std.testing.expectEqual(@as(u32, 0x0107), unit.read(at(drw.off.control2), 2));
    try std.testing.expectEqual(@as(u32, 0x0FBE), unit.read(at(drw.off.control2 + 2), 2));
    try std.testing.expectEqual(@as(u32, 0xBE), unit.read(at(drw.off.control2 + 2), 1));
}

test "an ORIGIN half laid on top of the other triggers the box it makes" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();

    programFill(&bench.unit, 2, 2, 8, 0xFFFF_0000);
    bench.unit.write(at(drw.off.origin), 2, fb_base & 0xFFFF);
    bench.unit.write(at(drw.off.origin + 2), 2, fb_base >> 16);
    try std.testing.expectEqual(fb_base, bench.unit.origin);
    try std.testing.expectEqual(@as(u32, 1), bench.unit.renders);
    try std.testing.expectEqual(@as(u64, 4), bench.unit.pixels);
}
