//! Editing from the registers and memory panes (RA8EMU-742): which value a
//! click lands on, and writing what the hex field commits back through the
//! session. The panes stay pure draw producers; the shell routes a button
//! press to `registerAt`/`byteAt`, keys and text to `Edit`, and draws the
//! field with `fieldOrigin`.
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const hex_entry = @import("ui/hex_entry.zig");
const memory_pane = @import("ui/memory_pane.zig");
const registers_capture = @import("registers_capture.zig");
const registers_pane = @import("ui/registers_pane.zig");
const session_api = @import("ra8_session").session_api;

const Rect = draw_list.Rect;

pub const Target = union(enum) {
    /// An index into registers_capture.shown.
    register: usize,
    byte: u32,
};

pub const State = enum { editing, written, cancelled };

/// The register whose value text a click at (x, y) lands on.
pub fn registerAt(area: Rect, x: i32, y: i32) ?usize {
    for (0..registers_pane.names.len) |index| {
        const cell = registers_pane.cellRect(area, registers_pane.open, index) orelse return null;
        const at = registers_pane.valueOrigin(cell);
        const w: i32 = @intCast(font.textWidth(8));
        if (x >= at.x and x < at.x + w and y >= cell.y and y < cell.y + cell.h) return index;
    }
    return null;
}

/// The readable byte whose hex digits a click at (x, y) lands on.
pub fn byteAt(area: Rect, snapshot: *const memory_pane.Snapshot, x: i32, y: i32) ?u32 {
    const top = memory_pane.rowOrigin(area, 0);
    if (y < top.y - 2) return null;
    const row: usize = @intCast(@divTrunc(y - (top.y - 2), memory_pane.row_h));
    if (row >= @min(memory_pane.rows(area), snapshot.count)) return null;
    for (0..memory_pane.per_row) |index| {
        const hex_x = top.x + @as(i32, @intCast(font.textWidth(memory_pane.hexColumn(index))));
        if (x < hex_x or x >= hex_x + @as(i32, @intCast(font.textWidth(2)))) continue;
        if (!snapshot.readable[row * memory_pane.per_row + index]) return null;
        return snapshot.rowAddress(row) +% @as(u32, @intCast(index));
    }
    return null;
}

/// Where the field's text starts over a register's value.
pub fn registerOrigin(area: Rect, index: usize) ?struct { x: i32, y: i32 } {
    const cell = registers_pane.cellRect(area, registers_pane.open, index) orelse return null;
    const at = registers_pane.valueOrigin(cell);
    return .{ .x = at.x, .y = at.y };
}

pub const Edit = struct {
    target: Target,
    field: hex_entry.Field,

    pub fn begin(target: Target) Edit {
        return .{ .target = target, .field = hex_entry.Field.init(switch (target) {
            .register => 8,
            .byte => 2,
        }) };
    }

    pub fn typed(self: *Edit, text: []const u8) void {
        self.field.typed(text);
    }

    /// Feeds a key to the field; a commit writes the value through the
    /// session before it says so.
    pub fn key(self: *Edit, code: u32, session: *session_api.Session, core: session_api.Core) anyerror!State {
        switch (self.field.key(code)) {
            .typing => return .editing,
            .cancel => return .cancelled,
            .commit => |value| {
                switch (self.target) {
                    .register => |index| try session.setRegister(core, registers_capture.shown[index], value),
                    .byte => |address| try session.write(core, address, &.{@truncate(value)}),
                }
                return .written;
            },
        }
    }
};
