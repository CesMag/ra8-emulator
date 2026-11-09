//! Host process health cards and a minute of CPU/RAM history (RA8EMU-1239).
const std = @import("std");
const metrics = @import("ra8_host").metrics;
const widget = @import("ra8_widget");
const render = @import("ra8_render");
const Rect = render.draw_list.Rect;
const Color = render.draw_list.Color;
const Theme = @import("colors.zig").Theme;
const row_h: i32 = @intCast(render.font.cell_h + 6);

pub fn draw(table: *const widget.types.Paint, theme: *const Theme, area: Rect, sampler: *const metrics.Sampler) void {
    if (area.w <= 8 or area.h <= 8) return;
    table.push_clip.?(table.user, area.x, area.y, area.w, area.h);
    defer table.pop_clip.?(table.user);
    fill(table, area, theme.background);
    const sample = sampler.current orelse {
        line(table, theme, area, 0, "Host metrics unavailable");
        return;
    };
    var buf: [160]u8 = undefined;
    line(table, theme, area, 0, if (sampler.available) "LIVE HOST PROCESS" else "HOST PROCESS (stale)");
    var row: i32 = 1;
    metric(table, theme, area, &row, &buf, "CPU {d:.1}% (100%=1 core)", .{sample.cpu_percent});
    metric(table, theme, area, &row, &buf, "Machine share {d:.1}%", .{sample.cpu_total_percent});
    metric(table, theme, area, &row, &buf, "Footprint {d} MiB", .{sample.footprint / 1048576});
    metric(table, theme, area, &row, &buf, "Peak {d} MiB", .{sample.peak_footprint / 1048576});
    metric(table, theme, area, &row, &buf, "RSS {d} MiB / VSZ {d} MiB", .{ sample.rss / 1048576, sample.vsz / 1048576 });
    metric(table, theme, area, &row, &buf, "Threads {d}", .{sample.threads});
    if (sample.swap_available) {
        metric(table, theme, area, &row, &buf, "Swap {d} MiB", .{sample.swap / 1048576});
    } else {
        line(table, theme, area, row, "Swap unavailable");
        row += 1;
    }
    const top = area.y + 4 + (row + 1) * row_h;
    const height = @min(64, @divTrunc(area.y + area.h - top - row_h - 8, 2));
    if (height < 8) return;
    var cpu_max: f64 = 100;
    var ram_max: u64 = 1;
    for (0..sampler.count) |i| {
        cpu_max = @max(cpu_max, sampler.at(i).cpu_percent);
        ram_max = @max(ram_max, sampler.at(i).footprint);
    }
    metric(table, theme, area, &row, &buf, "CPU 60s / scale {d:.0}%", .{cpu_max});
    graph(table, theme, .{ .x = area.x + 4, .y = top, .w = area.w - 8, .h = height }, sampler, false);
    const ram_area: Rect = .{ .x = area.x, .y = top + height, .w = area.w, .h = row_h };
    const ram_label = std.fmt.bufPrint(&buf, "RAM 60s / scale {d} MiB", .{ram_max / 1048576}) catch return;
    line(table, theme, ram_area, 0, ram_label);
    graph(table, theme, .{ .x = area.x + 4, .y = top + height + row_h + 4, .w = area.w - 8, .h = height }, sampler, true);
}

fn metric(table: *const widget.types.Paint, theme: *const Theme, area: Rect, row: *i32, buf: []u8, comptime format: []const u8, args: anytype) void {
    line(table, theme, area, row.*, std.fmt.bufPrint(buf, format, args) catch return);
    row.* += 1;
}

fn graph(table: *const widget.types.Paint, theme: *const Theme, area: Rect, sampler: *const metrics.Sampler, ram: bool) void {
    fill(table, area, theme.well);
    var ceiling: f64 = if (ram) 1 else 100;
    for (0..sampler.count) |i| {
        const sample = sampler.at(i);
        ceiling = @max(ceiling, if (ram) @as(f64, @floatFromInt(sample.footprint)) else sample.cpu_percent);
    }
    for (0..sampler.count) |i| {
        const sample = sampler.at(i);
        const value = if (ram) @as(f64, @floatFromInt(sample.footprint)) else sample.cpu_percent;
        const h: i32 = @intFromFloat(value / ceiling * @as(f64, @floatFromInt(area.h - 1)));
        const x = area.x + @divTrunc(@as(i32, @intCast(metrics.capacity - sampler.count + i)) * area.w, metrics.capacity);
        fill(table, .{ .x = x, .y = area.y + area.h - 1 - h, .w = @max(1, @divTrunc(area.w, metrics.capacity)), .h = 2 }, if (ram) theme.hue.green else theme.hue.blue);
    }
}
fn line(table: *const widget.types.Paint, theme: *const Theme, area: Rect, row: i32, text: []const u8) void {
    const bg = if (row >= 1 and row <= 7) theme.surface else theme.background;
    if (row >= 1 and row <= 7) fill(table, .{ .x = area.x + 2, .y = area.y + 2 + row * row_h, .w = area.w - 4, .h = row_h - 2 }, bg);
    var buffer: [192]u8 = undefined;
    const fitted = render.font.fit(text, @intCast(@max(area.w - 8, 0)));
    const n = @min(fitted.len, buffer.len - 1);
    @memcpy(buffer[0..n], fitted[0..n]);
    buffer[n] = 0;
    var descriptor = widget.label.Label{ .paint = table, .text = buffer[0..n :0].ptr, .fg = word(theme.ink), .bg = word(bg), .pad = 0, .alignment = .left, .face = .sans };
    var w: widget.types.Widget = undefined;
    _ = widget.label.ra8_widget_label_init(&w, &descriptor);
    w.rect = .{ .x = area.x + 4, .y = area.y + 4 + row * row_h, .w = @intCast(render.font.textWidth(n)), .h = @intCast(render.font.cell_h) };
    w.vt.?.render.?(&w);
}
fn fill(table: *const widget.types.Paint, area: Rect, color: Color) void {
    table.fill_rect.?(table.user, area.x, area.y, area.w, area.h, word(color));
}
fn word(color: Color) u32 {
    return @as(u32, color.r) << 16 | @as(u32, color.g) << 8 | color.b;
}
