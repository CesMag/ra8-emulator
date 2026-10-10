//! Covers src/chip/periph/glcdc/mix.zig: compositing the graphics layers onto
//! the background colour, which dev never does at all.
const std = @import("std");
const ra8 = @import("ra8");

const mix = ra8.chip.periph.glcdc_mix;
const scan = ra8.chip.periph.glcdc_scan;
const blend = ra8.chip.periph.glcdc_blend;
const clut = ra8.chip.periph.glcdc_clut;
const pixel = ra8.chip.periph.glcdc_pixel;
const store_memory = @import("../store_memory.zig");
const Guest = store_memory.Guest;
const memmap = ra8.chip.core.memmap;

const lower_base: u32 = memmap.sram_base;
const upper_base: u32 = memmap.sram_base + 0x1000;

fn shape(base: u32, width: u32, height: u32) scan.Shape {
    const format = pixel.Format.argb8888;
    return .{
        .base = base,
        .width = width,
        .height = height,
        .stride = width * 4,
        .bits = format.bits(),
        .decode = format.decoder(),
        .indexed = format.indexed(),
        .window_end = memmap.sram_end,
    };
}

/// Fill a framebuffer with one ARGB8888 colour.
fn fill(core: Guest, base: u32, count: u32, colour: u32) !void {
    var word: [4]u8 = undefined;
    std.mem.writeInt(u32, &word, colour, .little);
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        try core.write(base + index * 4, &word);
    }
}

fn stage(width: u32, height: u32, mode: blend.Display) blend.Layer {
    var out = blend.Layer{};
    out.ab1 = blend.field.grcdispon | @backingInt(mode);
    out.ab2 = height & blend.field.size_mask;
    out.ab3 = width & blend.field.size_mask;
    return out;
}

test "with no layer on it the panel is the background colour" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    var mixer = mix.Mixer{};
    const out = mixer.run(core, .{ .width = 2, .height = 2, .background = 0x0000_FF00 }, &.{});
    const picture = out.picture;
    try std.testing.expectEqual(@as(u32, 4), picture.pixels);
    try std.testing.expectEqual(@as(u32, 1), picture.colours);
    try std.testing.expectEqual(@as(u32, 0), picture.blank);
    try std.testing.expectEqual(@as(u32, 4), mixer.bare);
}

test "one displayed layer covers the background it sits on" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    try fill(core, lower_base, 4, 0xFF11_2233);
    var lower = stage(2, 2, .shown);
    var mixer = mix.Mixer{};
    var palette = clut.Palette{};
    const planes = [_]mix.Plane{
        .{ .shape = shape(lower_base, 2, 2), .palette = &palette, .stage = &lower },
    };
    const out = mixer.run(core, .{ .width = 2, .height = 2, .background = 0x0000_FF00 }, &planes);
    try std.testing.expectEqual(@as(u32, 1), out.picture.colours);
    try std.testing.expectEqual(@as(u32, 0), mixer.bare);
    try std.testing.expectEqual(@as(u32, 4), lower.shown);
}

test "an upper layer in its own rectangle covers only what it reaches" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    try fill(core, lower_base, 4, 0xFF11_2233);
    try fill(core, upper_base, 1, 0xFFAA_BBCC);
    var lower = stage(2, 2, .shown);
    var upper = stage(1, 1, .shown);
    var palette = clut.Palette{};
    var mixer = mix.Mixer{};
    const planes = [_]mix.Plane{
        .{ .shape = shape(lower_base, 2, 2), .palette = &palette, .stage = &lower },
        .{ .shape = shape(upper_base, 1, 1), .palette = &palette, .stage = &upper },
    };
    const out = mixer.run(core, .{ .width = 2, .height = 2, .background = 0 }, &planes);
    // Two colours on the panel: the overlay in one corner, the lower layer
    // in the other three. dev would have reported one framebuffer or the
    // other, never both.
    try std.testing.expectEqual(@as(u32, 2), out.picture.colours);
    try std.testing.expectEqual(@as(u32, 1), mixer.overlapped);
    try std.testing.expectEqual(@as(u32, 1), upper.shown);
    try std.testing.expectEqual(@as(u32, 4), lower.shown);
}

test "a transparent upper layer lets the lower one through" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    try fill(core, lower_base, 4, 0xFF11_2233);
    try fill(core, upper_base, 4, 0xFFAA_BBCC);
    var lower = stage(2, 2, .shown);
    var upper = stage(2, 2, .transparent);
    var palette = clut.Palette{};
    var mixer = mix.Mixer{};
    const planes = [_]mix.Plane{
        .{ .shape = shape(lower_base, 2, 2), .palette = &palette, .stage = &lower },
        .{ .shape = shape(upper_base, 2, 2), .palette = &palette, .stage = &upper },
    };
    const out = mixer.run(core, .{ .width = 2, .height = 2, .background = 0 }, &planes);
    try std.testing.expectEqual(@as(u32, 1), out.picture.colours);
    try std.testing.expectEqual(@as(u32, 0), mixer.overlapped);
    try std.testing.expectEqual(@as(u32, 4), upper.hidden);
}

test "a half-transparent blended layer mixes with what is under it" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    try fill(core, lower_base, 1, 0xFF00_0000);
    try fill(core, upper_base, 1, 0x80FF_FFFF);
    var lower = stage(1, 1, .shown);
    var upper = stage(1, 1, .blended);
    var palette = clut.Palette{};
    var mixer = mix.Mixer{};
    const planes = [_]mix.Plane{
        .{ .shape = shape(lower_base, 1, 1), .palette = &palette, .stage = &lower },
        .{ .shape = shape(upper_base, 1, 1), .palette = &palette, .stage = &upper },
    };
    const out = mixer.run(core, .{ .width = 1, .height = 1, .background = 0 }, &planes);
    try std.testing.expectEqual(@as(u32, 1), out.picture.pixels);
    try std.testing.expectEqual(@as(u32, 1), mixer.overlapped);
    // Mid grey, not either source colour.
    const mixed = blend.over(0x80FF_FFFF, 0xFF00_0000);
    try std.testing.expect(mixed != 0xFF00_0000 and mixed != 0xFFFF_FFFF);
}

test "a panel row past the end of a layer's rectangle shows the background" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    try fill(core, lower_base, 2, 0xFF11_2233);
    var lower = stage(2, 1, .shown);
    var palette = clut.Palette{};
    var mixer = mix.Mixer{};
    const planes = [_]mix.Plane{
        .{ .shape = shape(lower_base, 2, 1), .palette = &palette, .stage = &lower },
    };
    _ = mixer.run(core, .{ .width = 2, .height = 2, .background = 0x0000_FF00 }, &planes);
    try std.testing.expectEqual(@as(u32, 2), mixer.bare);
    try std.testing.expectEqual(@as(u32, 2), lower.shown);
}

test "a CLUT layer over an empty palette refuses the whole panel" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    var lower = stage(2, 2, .shown);
    var palette = clut.Palette{};
    var indexed = shape(lower_base, 2, 2);
    indexed.indexed = true;
    indexed.bits = 8;
    const planes = [_]mix.Plane{
        .{ .shape = indexed, .palette = &palette, .stage = &lower },
    };
    var mixer = mix.Mixer{};
    const out = mixer.run(core, .{ .width = 2, .height = 2, .background = 0 }, &planes);
    try std.testing.expectEqual(scan.Refusal.no_palette, out.refused);
    try std.testing.expect(mixer.quiet());
}

test "a framebuffer running off the end of its RAM window refuses the panel" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    var lower = stage(2, 2, .shown);
    var palette = clut.Palette{};
    var past = shape(lower_base, 2, 2);
    past.window_end = lower_base + 4;
    const planes = [_]mix.Plane{
        .{ .shape = past, .palette = &palette, .stage = &lower },
    };
    var mixer = mix.Mixer{};
    const out = mixer.run(core, .{ .width = 2, .height = 2, .background = 0 }, &planes);
    try std.testing.expectEqual(scan.Refusal.off_ram, out.refused);
}
