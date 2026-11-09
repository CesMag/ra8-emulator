const std = @import("std");
const ra8 = @import("ra8");
const gui = @import("gui_app");
const metrics = ra8.session.device_metrics;

test "device metrics pane paints pinned and low stack warnings with bounded geometry" {
    const theme = &gui.colors.palettes.dark;
    var list = ra8.render.draw_list.DrawList.init(std.testing.allocator, 400, 480);
    defer list.deinit();
    var target: ra8.render.widget_paint.Target = .{ .list = &list };
    const snapshot: metrics.Snapshot = .{
        .attached = true,
        .active = 100,
        .msp = .{ .pointer = 1001, .limit = 1000, .top = 2000 },
        .sram = .{ .pages = 2, .capacity = 1024 * 1024 },
        .sdram = .{ .capacity = 128 * 1024 * 1024 },
    };
    const window: metrics.Window = .{ .percent = 100, .pinned = true };
    gui.device_metrics_pane.draw(&target.paint(), theme, .{ .x = 0, .y = 0, .w = 400, .h = 480 }, &snapshot, &window);
    try std.testing.expect(list.commands.items.len > 0);
    var framebuffer = try ra8.render.raster.Framebuffer.init(std.testing.allocator, 400, 480);
    defer framebuffer.deinit(std.testing.allocator);
    ra8.render.raster.draw(&framebuffer, &list, ra8.render.font.atlas);
    try std.testing.expect(std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(framebuffer.pixels)) != 0);
}

test "device metrics badge and RTOS gauges stay clipped in narrow dark and light panes" {
    var list = ra8.render.draw_list.DrawList.init(std.testing.allocator, 800, 600);
    defer list.deinit();
    var target = ra8.render.widget_paint.Target{ .list = &list };
    const area: ra8.render.draw_list.Rect = .{ .x = 11, .y = 13, .w = 240, .h = 500 };
    var snapshot: metrics.Snapshot = .{ .attached = true, .rtos = true, .owner_count = 1 };
    snapshot.owners[0] = .{ .owner = .{ .kind = .exception, .id = 15 }, .ticks = 40 };
    for ([_]*const gui.colors.Theme{ &gui.colors.palettes.light, &gui.colors.palettes.dark }) |theme| {
        list.commands.clearRetainingCapacity();
        gui.device_metrics_pane.draw(&target.paint(), theme, area, &snapshot, &.{ .percent = 100, .pinned = true });
        var badge = false;
        var isr_gauge = false;
        for (list.commands.items) |command| {
            try std.testing.expectEqualDeep(area, command.clip);
            if (command.shape == .fill) {
                const fill = command.shape.fill;
                if (std.meta.eql(fill.color, theme.selected_face)) badge = true;
                if (std.meta.eql(fill.color, theme.hue.purple) and fill.area.w > 0) isr_gauge = true;
            }
        }
        try std.testing.expect(badge);
        try std.testing.expect(isr_gauge);
    }
}

test "crowded RTOS shares show busiest owners using the complete denominator" {
    var list = ra8.render.draw_list.DrawList.init(std.testing.allocator, 240, 300);
    defer list.deinit();
    var target = ra8.render.widget_paint.Target{ .list = &list };
    const theme = &gui.colors.palettes.dark;
    var snapshot: metrics.Snapshot = .{ .attached = true, .rtos = true, .owner_count = 4, .other = 25 };
    for ([_]u64{ 10, 40, 20, 5 }, 0..) |ticks, i| {
        snapshot.owners[i] = .{ .owner = .{ .kind = .thread, .id = @intCast(i) }, .ticks = ticks };
    }
    gui.device_metrics_pane.draw(&target.paint(), theme, .{ .x = 0, .y = 0, .w = 240, .h = 300 }, &snapshot, &.{});
    var widths: [2]i32 = undefined;
    var count: usize = 0;
    for (list.commands.items) |command| {
        if (command.shape != .fill) continue;
        const fill = command.shape.fill;
        if (!std.meta.eql(fill.color, theme.hue.blue) or fill.area.w <= 0) continue;
        try std.testing.expect(count < widths.len);
        widths[count] = fill.area.w;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualSlices(i32, &.{ 92, 46 }, &widths);
}

test "restored device memory shows unavailable usage without a false empty gauge" {
    var list = ra8.render.draw_list.DrawList.init(std.testing.allocator, 400, 480);
    defer list.deinit();
    var target = ra8.render.widget_paint.Target{ .list = &list };
    const theme = &gui.colors.palettes.dark;
    const snapshot: metrics.Snapshot = .{
        .attached = true,
        .sram = .{ .known = false, .pages = 99, .capacity = 1664 * 1024 },
        .sdram = .{ .known = false, .pages = 99, .capacity = 128 * 1024 * 1024 },
    };
    gui.device_metrics_pane.draw(&target.paint(), theme, .{ .x = 0, .y = 0, .w = 400, .h = 480 }, &snapshot, &.{});
    var tracks: usize = 0;
    for (list.commands.items) |command| {
        if (command.shape != .fill) continue;
        const color = command.shape.fill.color;
        try std.testing.expect(!std.meta.eql(color, theme.hue.green));
        if (std.meta.eql(color, theme.border)) tracks += 1;
    }
    // Only the CPU's gauge remains; neither memory region has a usage gauge.
    try std.testing.expectEqual(@as(usize, 1), tracks);
}
