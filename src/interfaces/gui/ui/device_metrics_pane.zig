//! Guest health cards, with interval CPU load and RTOS ownership (RA8EMU-1240).
const std = @import("std");
const metrics = @import("ra8_session").device_metrics;
const widget = @import("ra8_widget");
const font = @import("ra8_render").font;
const Color = @import("ra8_render").draw_list.Color;
const Rect = @import("ra8_render").draw_list.Rect;
const Theme = @import("colors.zig").Theme;
const row_h: i32 = @intCast(font.cell_h + 10);

pub fn draw(table: *const widget.types.Paint, theme: *const Theme, area: Rect, snapshot: *const metrics.Snapshot, window: *const metrics.Window) void {
    if (area.w < 100 or area.h < row_h) return;
    table.push_clip.?(table.user, area.x, area.y, area.w, area.h);
    defer table.pop_clip.?(table.user);
    table.fill_rect.?(table.user, area.x, area.y, area.w, area.h, word(theme.background));
    var painter: Painter = .{ .table = table, .theme = theme, .area = area };
    if (!snapshot.attached) {
        painter.line("core not attached", theme.muted);
        return;
    }
    var buf: [128]u8 = undefined;
    const cpu = if (area.w < 160 and window.pinned) std.fmt.bufPrint(&buf, "{d}% PINNED", .{window.percent}) catch return else std.fmt.bufPrint(&buf, "CPU {d}%", .{window.percent}) catch return;
    painter.card = true;
    painter.line(cpu, if (window.pinned) theme.bad else theme.ink);
    if (window.pinned) painter.badge("PINNED");
    painter.gauge(window.percent, 100, theme.hue.blue);
    painter.line("RAM shared by both cores", theme.muted);
    painter.memory("SRAM", snapshot.sram, &buf);
    painter.memory("SDRAM", snapshot.sdram, &buf);
    painter.stack("MSP", snapshot.msp, &buf);
    painter.stack("PSP", snapshot.psp, &buf);
    painter.card = false;
    if (!snapshot.rtos) {
        painter.line("RTOS load unavailable", theme.muted);
        return;
    }
    drawOwners(&painter, snapshot, &buf);
}

fn drawOwners(painter: *Painter, snapshot: *const metrics.Snapshot, buf: []u8) void {
    painter.line("RTOS cumulative active", painter.theme.muted);
    var total: u128 = snapshot.other;
    const count = @min(snapshot.owner_count, snapshot.owners.len);
    var indices: [32]usize = undefined;
    for (snapshot.owners[0..count], 0..) |owner, i| {
        total += owner.ticks;
        indices[i] = i;
        var at = i;
        while (at > 0 and owner.ticks > snapshot.owners[indices[at - 1]].ticks) : (at -= 1) {
            indices[at] = indices[at - 1];
        }
        indices[at] = i;
    }
    if (snapshot.other > 0) {
        const text = std.fmt.bufPrint(buf, "Other / untracked {d}%", .{@as(u128, snapshot.other) * 100 / total}) catch return;
        painter.line(text, painter.theme.muted);
    }
    const available: usize = @intCast(@max(0, @divTrunc(painter.area.h - 4, row_h) - painter.row));
    if (available == 0) return;
    const visible = @min(count, if (count > available) available - 1 else available);
    for (indices[0..visible]) |index| {
        const owner = snapshot.owners[index];
        const percent = if (total > 0) @as(u128, owner.ticks) * 100 / total else 0;
        const text = std.fmt.bufPrint(buf, "{s} {x}  {d}%", .{ @tagName(owner.owner.kind), owner.owner.id, percent }) catch continue;
        painter.line(text, painter.theme.ink);
        painter.gauge(@intCast(percent), 100, if (owner.owner.kind == .exception) painter.theme.hue.purple else painter.theme.hue.blue);
    }
    if (visible < count) painter.line(std.fmt.bufPrint(buf, "+ {d} more owners", .{count - visible}) catch return, painter.theme.muted);
}

const Painter = struct {
    table: *const widget.types.Paint,
    theme: *const Theme,
    area: Rect,
    row: i32 = 0,
    card: bool = false,
    fn line(self: *Painter, text: []const u8, color: Color) void {
        const y = self.area.y + 4 + self.row * row_h;
        self.row += 1;
        if (y + row_h > self.area.y + self.area.h) return;
        const bg = if (self.card) self.theme.surface else self.theme.background;
        if (self.card) self.table.fill_rect.?(self.table.user, self.area.x + 2, y - 2, self.area.w - 4, row_h - 1, word(bg));
        var buffer: [192]u8 = undefined;
        const fitted = font.fit(text, @intCast(@max(self.area.w - 8, 0)));
        const n = @min(fitted.len, buffer.len - 1);
        @memcpy(buffer[0..n], fitted[0..n]);
        buffer[n] = 0;
        var label: widget.label.Label = .{ .paint = self.table, .text = buffer[0..n :0].ptr, .fg = word(color), .bg = word(bg), .pad = 0, .alignment = .left, .face = .sans };
        var w: widget.types.Widget = undefined;
        _ = widget.label.ra8_widget_label_init(&w, &label);
        w.rect = .{ .x = self.area.x + 4, .y = y, .w = self.area.w - 8, .h = row_h - 4 };
        w.vt.?.render.?(&w);
    }
    fn badge(self: *Painter, text: []const u8) void {
        if (self.area.w < 160) return;
        const area: Rect = .{ .x = self.area.x + self.area.w - 68, .y = self.area.y + 2, .w = 64, .h = row_h - 1 };
        self.table.fill_rect.?(self.table.user, area.x, area.y, area.w, area.h, word(self.theme.selected_face));
        var buffer: [16]u8 = undefined;
        const n = @min(text.len, buffer.len - 1);
        @memcpy(buffer[0..n], text[0..n]);
        buffer[n] = 0;
        var label: widget.label.Label = .{ .paint = self.table, .text = buffer[0..n :0].ptr, .fg = word(self.theme.bad), .bg = word(self.theme.selected_face), .pad = 2, .alignment = .left, .face = .sans };
        var w: widget.types.Widget = undefined;
        _ = widget.label.ra8_widget_label_init(&w, &label);
        w.rect = .{ .x = area.x, .y = area.y, .w = area.w, .h = area.h };
        w.vt.?.render.?(&w);
    }
    fn gauge(self: *Painter, used: usize, capacity: usize, color: Color) void {
        const y = self.area.y + self.row * row_h;
        if (y + 3 > self.area.y + self.area.h) return;
        const width = @max(self.area.w - 8, 0);
        self.table.fill_rect.?(self.table.user, self.area.x + 4, y, width, 3, word(self.theme.border));
        const filled: i32 = if (capacity > 0) @intCast(@as(u128, @intCast(width)) * @min(used, capacity) / capacity) else 0;
        self.table.fill_rect.?(self.table.user, self.area.x + 4, y, filled, 3, word(color));
    }
    fn memory(self: *Painter, name: []const u8, value: metrics.Memory, buf: []u8) void {
        if (!value.known) {
            const capacity = std.fmt.bufPrint(buf, "{s}: {d} KiB capacity", .{ name, value.capacity / 1024 }) catch return;
            self.line(capacity, self.theme.ink);
            self.line("Page history unavailable", self.theme.muted);
            return;
        }
        const text = std.fmt.bufPrint(buf, "{s}: {d}/{d} KiB", .{ name, value.pages * 4, value.capacity / 1024 }) catch return;
        self.line(text, self.theme.ink);
        self.gauge(value.pages * 4096, value.capacity, self.theme.hue.green);
    }
    fn stack(self: *Painter, name: []const u8, value: metrics.Stack, buf: []u8) void {
        const text = if (value.known()) std.fmt.bufPrint(buf, "{s} {d}/{d} B {s}", .{ name, value.used(), value.top - value.limit, if (value.warning()) "LOW HEADROOM" else "" }) catch return else std.fmt.bufPrint(buf, "{s} {x:0>8} (no bounds)", .{ name, value.pointer }) catch return;
        self.line(text, if (value.warning()) self.theme.bad else self.theme.ink);
        if (value.known()) self.gauge(value.used(), value.top - value.limit, if (value.warning()) self.theme.bad else self.theme.hue.purple);
    }
};
fn word(color: Color) u32 {
    return @as(u32, color.r) << 16 | @as(u32, color.g) << 8 | color.b;
}
