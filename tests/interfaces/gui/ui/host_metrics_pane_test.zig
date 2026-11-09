const std = @import("std");
const ra8 = @import("ra8");
const gui = @import("gui_app");
const pane = gui.host_metrics_pane;

test "host metrics paints empty, live and stale histories in both themes" {
    var list = ra8.render.draw_list.DrawList.init(std.testing.allocator, 400, 360);
    defer list.deinit();
    var target = ra8.render.widget_paint.Target{ .list = &list };
    const area: ra8.render.draw_list.Rect = .{ .x = 0, .y = 0, .w = 400, .h = 360 };
    var sampler: ra8.host.metrics.Sampler = .{};
    pane.draw(&target.paint(), &gui.colors.palettes.dark, area, &sampler);
    for (0..125) |i| sampler.record(.{ .cpu_ns = i * 1000, .footprint = i * 4096, .threads = 3 }, i * 2000);
    pane.draw(&target.paint(), &gui.colors.palettes.dark, area, &sampler);
    sampler.available = false;
    pane.draw(&target.paint(), &gui.colors.palettes.light, area, &sampler);
    pane.draw(&target.paint(), &gui.colors.palettes.light, .{ .x = 0, .y = 0, .w = 0, .h = 0 }, &sampler);
    try std.testing.expect(list.commands.items.len > 0);
}

test "narrow host pane clips labels and anchors newest graph sample at the right edge" {
    var list = ra8.render.draw_list.DrawList.init(std.testing.allocator, 800, 600);
    defer list.deinit();
    var target = ra8.render.widget_paint.Target{ .list = &list };
    const area: ra8.render.draw_list.Rect = .{ .x = 11, .y = 13, .w = 240, .h = 500 };
    for ([_]*const gui.colors.Theme{ &gui.colors.palettes.light, &gui.colors.palettes.dark }) |theme| {
        list.commands.clearRetainingCapacity();
        var sampler: ra8.host.metrics.Sampler = .{};
        sampler.record(.{ .footprint = 123 * 1048576, .threads = 8 }, 0);
        sampler.record(.{ .footprint = 124 * 1048576, .cpu_ns = 500_000_000, .threads = 8 }, 1_000_000_000);
        pane.draw(&target.paint(), theme, area, &sampler);
        var latest = false;
        for (list.commands.items) |command| {
            try std.testing.expectEqualDeep(area, command.clip);
            if (command.shape == .fill) {
                const fill = command.shape.fill;
                if (std.meta.eql(fill.color, theme.hue.blue) and fill.area.x >= area.x + area.w - 12) latest = true;
            }
        }
        try std.testing.expect(latest);
    }
}
