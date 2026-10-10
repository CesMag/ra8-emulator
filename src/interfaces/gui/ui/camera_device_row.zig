//! The webcam device row under the camera panel (RA8EMU-500): one slot per
//! /dev/videoN the host lists (camera_devices.zig), the chosen one ringed.
//! A click on a slot names that device; the pane turns it into the webcam
//! argument. Each slot is labelled vN for /dev/videoN (RA8EMU-677).
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const camera_view = @import("camera_view.zig");
const font = @import("ra8_render").font;
const Rect = draw_list.Rect;

pub const slot_color = camera_view.camera_off;

/// The row's top-left corner, set under the panel's dialog row.
pub const Row = struct {
    x: i32,
    y: i32,

    pub fn under(layout: camera_view.Layout) Row {
        const panel = layout.area();
        return .{ .x = panel.x, .y = panel.y + panel.h };
    }

    pub fn slot(self: Row, index: usize) Rect {
        const at: i32 = @intCast(index);
        const step = camera_view.button + camera_view.gap;
        return .{ .x = self.x + camera_view.gap + at * step, .y = self.y, .w = camera_view.button, .h = camera_view.button };
    }

    pub fn area(self: Row, count: usize) Rect {
        const n: i32 = @intCast(count);
        const w = n * (camera_view.button + camera_view.gap) + camera_view.gap;
        return .{ .x = self.x, .y = self.y, .w = w, .h = camera_view.button + camera_view.gap };
    }
};

/// Appends the row for `devices` with `chosen` ringed. No devices, no row.
pub fn draw(list: *draw_list.DrawList, row: Row, devices: []const u32, chosen: ?u32) !void {
    if (devices.len == 0) return;
    try list.fill(row.area(devices.len), camera_view.background);
    for (devices, 0..) |device, index| {
        const at = row.slot(index);
        if (chosen != null and chosen.? == device) {
            try list.fill(.{ .x = at.x - 2, .y = at.y - 2, .w = at.w + 4, .h = at.h + 4 }, camera_view.ring);
        }
        try list.fill(at, slot_color);
        var text: [12]u8 = undefined;
        const label = std.fmt.bufPrint(&text, "v{d}", .{device}) catch "v?";
        try font.centred(list, at, label, camera_view.inkOn(slot_color));
    }
}

/// The device under (`x`, `y`), or null when the click missed every slot.
pub fn hit(row: Row, devices: []const u32, x: i32, y: i32) ?u32 {
    for (devices, 0..) |device, index| {
        if (row.slot(index).contains(x, y)) return device;
    }
    return null;
}
