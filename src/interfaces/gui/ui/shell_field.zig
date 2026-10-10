//! A one-line text field for the shell (RA8EMU-803). It is the firmware's
//! own text field (ra8_widget.text_field, the widget the board renders),
//! painted into the draw list through widget_paint (RA8EMU-719), so the
//! shell and the board share one editing behaviour. Typed characters arrive
//! as the window's text events and Backspace and Enter as key events; a
//! press inside the field focuses it and one outside lets it go.
const std = @import("std");
const widget = @import("ra8_widget");
const platform = @import("../platform.zig");
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const widget_paint = @import("ra8_render").widget_paint;

const text_field = widget.text_field;

/// Bytes the field holds, its trailing NUL included.
pub const capacity: u16 = 256;
/// The field is a glyph tall plus a little air.
pub const height: i32 = @as(i32, @intCast(font.cell_h)) + 6;

pub const ink: u32 = 0xD8DEE9;
pub const fill: u32 = 0x181A1F;
pub const caret: u32 = 0xEBCB8B;

pub const Field = struct {
    buffer: [capacity]u8 = undefined,
    descriptor: text_field.TextField = undefined,
    widget: widget.types.Widget = undefined,

    /// Set the field up in place; it must not move afterwards, since the
    /// widget points at its descriptor and the descriptor at its buffer.
    pub fn init(self: *Field, placeholder: [*:0]const u8) !void {
        self.descriptor = .{ .paint = null, .buffer = &self.buffer, .capacity = capacity, .len = 0, .placeholder = placeholder, .fg = ink, .bg = fill, .caret = caret, .pad = 3, .face = .sans };
        self.widget = .{ .vt = null, .ctx = null, .rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 }, .fixed = 0, .flex = 0, .action_id = 0, .refresh = 0, .visible = false, .dirty = false };
        if (text_field.ra8_widget_text_field_init(&self.widget, &self.descriptor) != text_field.err.ok) return error.FieldRefused;
    }

    pub fn value(self: *const Field) []const u8 {
        return self.buffer[0..self.descriptor.len];
    }

    pub fn focused(self: *const Field) bool {
        return self.descriptor.focused;
    }

    /// Empty the field, keeping its focus.
    pub fn clear(self: *Field) void {
        self.descriptor.len = 0;
        self.buffer[0] = 0;
    }

    /// A left press at (`x`, `y`): focus the field when it lands inside the
    /// field's last drawn rect, let it go otherwise. Returns whether the
    /// press was the field's.
    pub fn press(self: *Field, x: i32, y: i32) bool {
        const rect = self.widget.rect;
        const inside = x >= rect.x and y >= rect.y and x < rect.x + rect.w and y < rect.y + rect.h;
        if (!inside) {
            self.descriptor.focused = false;
            return false;
        }
        const event: widget.types.Event = .{ .kind = .touch, .reserved = 0, .button_id = 0, .x = x, .y = y };
        return self.widget.vt.?.on_input.?(&self.widget, &event);
    }

    /// Feed one window event to the focused field. Returns whether the field
    /// changed or was submitted.
    pub fn handle(self: *Field, event: platform.Event) bool {
        if (!self.focused()) return false;
        return switch (event) {
            .text => |typed| self.typeBytes(typed.slice()),
            .key => |key| key.down and self.control(key.code),
            else => false,
        };
    }

    fn typeBytes(self: *Field, bytes: []const u8) bool {
        var changed = false;
        for (bytes) |byte| {
            if (byte < 0x20 or byte > 0x7E) continue;
            const action: widget.types.KeyAction = if (byte == ' ') .space else .character;
            changed = text_field.applyKey(&self.widget, action, byte) or changed;
        }
        return changed;
    }

    fn control(self: *Field, code: u32) bool {
        const action: widget.types.KeyAction = switch (code) {
            0x08 => .backspace,
            0x0D => .enter,
            else => return false,
        };
        return text_field.applyKey(&self.widget, action, 0);
    }

    /// Whether Enter was pressed since the last call; asking clears it.
    pub fn takeSubmit(self: *Field) bool {
        const submitted = self.descriptor.submitted;
        self.descriptor.submitted = false;
        return submitted;
    }

    /// Paint the field into `rect` of `list`, and remember `rect` for presses.
    pub fn draw(self: *Field, list: *draw_list.DrawList, rect: draw_list.Rect) !void {
        self.widget.rect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
        var target = widget_paint.Target{ .list = list };
        const paint = target.paint();
        self.descriptor.paint = &paint;
        defer self.descriptor.paint = null;
        self.widget.vt.?.render.?(&self.widget);
        if (target.failed) return error.OutOfMemory;
    }
};
