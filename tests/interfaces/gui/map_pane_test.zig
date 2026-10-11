//! Covers src/interfaces/gui/map_layout.zig and ui/map_pane.zig (RA8EMU-781)
//! on an EK-RA8D2 image: sections land in their regions with .data paired
//! across its load and run copies, a click on a block gives the address the
//! memory pane moves to, the hover text names the other copy, a pane too
//! small draws nothing, and the render matches a pinned golden frame.

const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const elf = ra8.board.image.elf;
const region_map = ra8.session.region_map;
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;
const dark = &gui_app.colors.palettes.dark;
const Theme = gui_app.colors.Theme;
const map_layout = gui_app.map_layout;
const pane = gui_app.map_pane;
const Rect = draw_list.Rect;

const image_bytes = @embedFile("../../fixtures/sections/fault_crashlog_hil.elf");
const area: Rect = .{ .x = 0, .y = 0, .w = 320, .h = 240 };

const image_path = "tests/fixtures/sections/fault_crashlog_hil.elf";
const stack = region_map.Stack{ .base = 0x220F_DF00, .size = 0x2000, .region = null };
const IN_DIGEST: u64 = 7368987722379181284;
const OVER_DIGEST: u64 = 10788268521560618784;

fn laidOut() !map_layout.Layout {
    return map_layout.build(try elf.Image.init(image_bytes), &region_map.ek_ra8d2);
}

fn named(layout: *const map_layout.Layout, name: []const u8, load: bool) ?usize {
    for (layout.items(), 0..) |block, index| {
        if (block.load == load and std.mem.eql(u8, block.name, name)) return index;
    }
    return null;
}

fn middle(layout: *const map_layout.Layout, index: usize) struct { x: i32, y: i32 } {
    var slots: [pane.max_bars]usize = undefined;
    const bars = layout.bars(&slots);
    const block = layout.blocks[index];
    const slot = std.mem.indexOfScalar(usize, bars, block.region).?;
    const box = pane.blockRect(layout, pane.barRect(area, slot, bars.len), block);
    return .{ .x = box.x + @divTrunc(box.w, 2), .y = box.y + @divTrunc(box.h, 2) };
}

fn digest(theme: *const Theme, layout: *const map_layout.Layout, hover: ?usize, path: [:0]const u8) !u64 {
    var list = draw_list.DrawList.init(std.testing.allocator, @intCast(area.w), @intCast(area.h));
    defer list.deinit();
    var frame = try raster.Framebuffer.init(std.testing.allocator, @intCast(area.w), @intCast(area.h));
    defer frame.deinit(std.testing.allocator);
    try pane.draw(&list, theme, area, layout, hover);
    raster.draw(&frame, &list, font.atlas);
    {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(std.testing.allocator);
        try out.print(std.testing.allocator, "P6\n{d} {d}\n255\n", .{ frame.width, frame.height });
        for (frame.pixels) |p| try out.appendSlice(std.testing.allocator, &.{ p.r, p.g, p.b });
        const file = std.c.fopen(path, "wb") orelse return error.Open;
        _ = std.c.fwrite(out.items.ptr, 1, out.items.len, file);
        _ = std.c.fclose(file);
    }
    return std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(frame.pixels));
}

test "code sits in MRAM and .data has a load copy in MRAM paired with its run copy in SRAM" {
    const layout = try laidOut();
    const mram = layout.map.find("MRAM").?;
    const sram = layout.map.find("SRAM").?;
    const text = layout.blocks[named(&layout, ".text", false).?];
    try std.testing.expectEqual(map_layout.Kind.code, text.kind);
    try std.testing.expectEqual(mram, text.region);
    const run = named(&layout, ".data", false).?;
    const load = named(&layout, ".data", true).?;
    try std.testing.expectEqual(sram, layout.blocks[run].region);
    try std.testing.expectEqual(mram, layout.blocks[load].region);
    try std.testing.expectEqual(load, layout.blocks[run].pair.?);
    try std.testing.expectEqual(run, layout.blocks[load].pair.?);
    var slots: [pane.max_bars]usize = undefined;
    for (layout.bars(&slots)) |region| try std.testing.expect(layout.map.regions[region].size != 0);
}

test "a click on a block gives its start, which moves the memory pane there" {
    const layout = try laidOut();
    const index = named(&layout, ".text", false).?;
    const at = middle(&layout, index);
    const address = pane.click(&layout, area, at.x, at.y).?;
    try std.testing.expectEqual(layout.blocks[index].start, address);
    var memory: gui_app.shell_memory.Memory = .{ .core = .cpu0 };
    memory.follow(address, memory.seen);
    try std.testing.expectEqual(address, memory.address);
    try std.testing.expect(memory.want);
    try std.testing.expectEqual(@as(?u32, null), pane.click(&layout, area, 0, 0));
}

test "the hover text names the range, the size and the other copy" {
    const layout = try laidOut();
    const run = layout.blocks[named(&layout, ".data", false).?];
    var buffer: [128]u8 = undefined;
    const text = try pane.describe(&buffer, &layout, run);
    try std.testing.expect(std.mem.startsWith(u8, text, ".data "));
    try std.testing.expect(std.mem.indexOf(u8, text, "loaded from") != null);
}

test "a pane too small draws nothing" {
    const layout = try laidOut();
    var list = draw_list.DrawList.init(std.testing.allocator, 20, 20);
    defer list.deinit();
    try pane.draw(&list, dark, .{ .x = 0, .y = 0, .w = 20, .h = 20 }, &layout, null);
    try std.testing.expectEqual(@as(usize, 0), list.commands.items.len);
}

test "the map with .data hovered rasterises to the pinned golden frame" {
    const layout = try laidOut();
    const hover = named(&layout, ".data", false).?;
    try std.testing.expectEqual(@as(u64, 14990597390328499780), try digest(dark, &layout, hover, "/tmp/map781.ppm"));
}

test "marks flag an overflow only when the lowest SP sat under the reservation" {
    var marks: map_layout.Marks = .{ .current = stack.base + 0x100, .low = stack.base + 0x800, .base = stack.base, .size = stack.size };
    try std.testing.expectEqual(@as(u32, 0), marks.overflowBytes());
    try std.testing.expect(!marks.overflowed());
    marks.touched = true;
    try std.testing.expect(!marks.overflowed());
    marks.low = stack.base - 0x40;
    try std.testing.expect(marks.overflowed());
    try std.testing.expectEqual(@as(u32, 0x40), marks.overflowBytes());
}

fn liveMarks(opened: *ra8.session.harness.Harness) !map_layout.Marks {
    const view = try opened.session().view(.cpu0);
    const marks = view.stack();
    const loaded = opened.loadedImage(.cpu0).?;
    const reservation = region_map.stackOf(loaded, &region_map.ek_ra8d2).?;
    const never = ra8.chip.core.cpu.regs.never_low;
    return .{
        .current = marks.msp,
        .low = marks.low_msp,
        .base = reservation.base,
        .size = reservation.size,
        .touched = marks.low_msp != never,
    };
}

test "a run's live stack draws the band and no red" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image_path });
    defer opened.deinit();
    opened.session().live.budget = 2_000;
    _ = try opened.session().run(.cpu0, .cont);
    const marks = try liveMarks(&opened);
    try std.testing.expect(marks.touched);
    try std.testing.expect(!marks.overflowed());
    var layout = try laidOut();
    layout.marks = marks;
    try std.testing.expectEqual(@as(u64, IN_DIGEST), try digest(dark, &layout, null, "/tmp/map815_in.ppm"));
}

test "an MSP set under the base draws the stack block red and the band runs on under it" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image_path });
    defer opened.deinit();
    try opened.session().setRegister(.cpu0, .msp, stack.base - 0x40);
    try opened.session().setRegister(.cpu0, .msp, stack.base + 0x100);
    const marks = try liveMarks(&opened);
    try std.testing.expect(marks.overflowed());
    try std.testing.expectEqual(@as(u32, 0x40), marks.overflowBytes());
    var layout = try laidOut();
    layout.marks = marks;
    try std.testing.expectEqual(@as(u64, OVER_DIGEST), try digest(dark, &layout, null, "/tmp/map815_over.ppm"));
}

test "marks that never set the SP draw the plain pane" {
    var layout = try laidOut();
    const plain = try digest(dark, &layout, null, "/tmp/map781.ppm");
    layout.marks = .{ .current = 0, .low = 0, .base = stack.base, .size = stack.size };
    try std.testing.expectEqual(plain, try digest(dark, &layout, null, "/tmp/map815_plain.ppm"));
}
