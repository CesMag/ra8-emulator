//! Script runner driving platform events from parsed actions (RA8EMU-1120).
const std = @import("std");
const action_mod = @import("action.zig");
const target_mod = @import("target.zig");
const platform = @import("../platform.zig");
const pane_layout = @import("../ui/pane_layout.zig");
const shell_board = @import("../shell/board/board.zig");

pub const Item = action_mod.Item;
pub const Event = platform.Event;
pub const Text = platform.Text;

pub const Ripple = struct {
    x: i32,
    y: i32,
    frame: u32,
    duration: u32 = 16,
};

pub const ActiveDrag = struct {
    from_x: i32,
    from_y: i32,
    to_x: i32,
    to_y: i32,
    start_ns: u64,
    duration_ns: u64,
};

pub const Runner = struct {
    allocator: std.mem.Allocator,
    items: []Item,
    events: std.ArrayListUnmanaged(Event) = .empty,
    cursor_x: i32 = 0,
    cursor_y: i32 = 0,
    ripples: std.ArrayListUnmanaged(Ripple) = .empty,
    active_drag: ?ActiveDrag = null,
    headless: bool = false,
    all_done: bool = false,
    last_action_frame: ?u32 = null,
    cooldown_frames: u32 = 30,

    pub fn init(allocator: std.mem.Allocator, items: []Item, headless: bool) Runner {
        return .{
            .allocator = allocator,
            .items = items,
            .headless = headless,
            .all_done = items.len == 0,
        };
    }

    pub fn deinit(self: *Runner) void {
        self.events.deinit(self.allocator);
        self.ripples.deinit(self.allocator);
    }

    pub fn poll(self: *Runner) ?Event {
        if (self.events.items.len == 0) return null;
        return self.events.orderedRemove(0);
    }

    pub fn advance(
        self: *Runner,
        layout: *const pane_layout.Layout,
        width: i32,
        height: i32,
        board: ?*const shell_board.Board,
        now_ns: u64,
        frame_idx: u32,
    ) !void {
        return self.advanceWithVirtual(layout, width, height, board, now_ns, 0, frame_idx);
    }

    pub fn advanceWithVirtual(
        self: *Runner,
        layout: *const pane_layout.Layout,
        width: i32,
        height: i32,
        board: ?*const shell_board.Board,
        wall_ns: u64,
        virtual_ns: u64,
        frame_idx: u32,
    ) !void {
        self.cleanRipples(frame_idx);

        if (self.active_drag) |drag| {
            try self.advanceDrag(drag, wall_ns);
        }

        var any_pending = false;
        for (self.items) |*item| {
            if (item.executed) continue;
            if (item.at.matchesWithVirtual(wall_ns, virtual_ns, frame_idx)) {
                try self.execute(layout, width, height, board, item.action, wall_ns, frame_idx);
                item.executed = true;
                self.last_action_frame = frame_idx;
            } else {
                any_pending = true;
            }
        }

        if (!any_pending and self.active_drag == null) {
            self.all_done = true;
            if (self.headless and self.last_action_frame != null) {
                if (frame_idx >= self.last_action_frame.? + self.cooldown_frames) {
                    try self.events.append(self.allocator, .quit);
                    self.last_action_frame = null;
                }
            }
        }
    }

    fn execute(
        self: *Runner,
        layout: *const pane_layout.Layout,
        width: i32,
        height: i32,
        board: ?*const shell_board.Board,
        action: action_mod.Action,
        now_ns: u64,
        frame_idx: u32,
    ) !void {
        switch (action) {
            .click => |tgt| {
                const pt = target_mod.resolve(self.allocator, layout, width, height, board, tgt) orelse return;
                self.cursor_x = pt.x;
                self.cursor_y = pt.y;
                try self.ripples.append(self.allocator, .{ .x = pt.x, .y = pt.y, .frame = frame_idx });
                try self.events.append(self.allocator, .{ .pointer = .{ .x = pt.x, .y = pt.y } });
                try self.events.append(self.allocator, .{ .button = .{ .button = 1, .down = true, .x = pt.x, .y = pt.y } });
                try self.events.append(self.allocator, .{ .button = .{ .button = 1, .down = false, .x = pt.x, .y = pt.y } });
            },
            .drag => |d| {
                self.cursor_x = d.from_x;
                self.cursor_y = d.from_y;
                try self.events.append(self.allocator, .{ .pointer = .{ .x = d.from_x, .y = d.from_y } });
                try self.events.append(self.allocator, .{ .button = .{ .button = 1, .down = true, .x = d.from_x, .y = d.from_y } });
                const dur_ns = @as(u64, d.duration_ms) * std.time.ns_per_ms;
                if (dur_ns == 0) {
                    self.cursor_x = d.to_x;
                    self.cursor_y = d.to_y;
                    try self.events.append(self.allocator, .{ .pointer = .{ .x = d.to_x, .y = d.to_y } });
                    try self.events.append(self.allocator, .{ .button = .{ .button = 1, .down = false, .x = d.to_x, .y = d.to_y } });
                } else {
                    self.active_drag = .{
                        .from_x = d.from_x,
                        .from_y = d.from_y,
                        .to_x = d.to_x,
                        .to_y = d.to_y,
                        .start_ns = now_ns,
                        .duration_ns = dur_ns,
                    };
                }
            },
            .type_text => |str| {
                var pos: usize = 0;
                while (pos < str.len) {
                    const chunk_len = @min(str.len - pos, 8);
                    const chunk = str[pos .. pos + chunk_len];
                    try self.events.append(self.allocator, .{ .text = Text.of(chunk) });
                    pos += chunk_len;
                }
            },
            .key => |k| {
                try self.events.append(self.allocator, .{ .key = .{ .code = k.code, .down = true, .shift = k.shift, .primary = k.primary } });
                try self.events.append(self.allocator, .{ .key = .{ .code = k.code, .down = false, .shift = k.shift, .primary = k.primary } });
            },
            .quit => {
                try self.events.append(self.allocator, .quit);
            },
        }
    }

    fn advanceDrag(self: *Runner, drag: ActiveDrag, now_ns: u64) !void {
        if (now_ns >= drag.start_ns + drag.duration_ns) {
            self.cursor_x = drag.to_x;
            self.cursor_y = drag.to_y;
            try self.events.append(self.allocator, .{ .pointer = .{ .x = drag.to_x, .y = drag.to_y } });
            try self.events.append(self.allocator, .{ .button = .{ .button = 1, .down = false, .x = drag.to_x, .y = drag.to_y } });
            self.active_drag = null;
        } else {
            const elapsed = now_ns - drag.start_ns;
            const progress = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(drag.duration_ns));
            const cur_x = drag.from_x + @as(i32, @intFromFloat(@as(f64, @floatFromInt(drag.to_x - drag.from_x)) * progress));
            const cur_y = drag.from_y + @as(i32, @intFromFloat(@as(f64, @floatFromInt(drag.to_y - drag.from_y)) * progress));
            self.cursor_x = cur_x;
            self.cursor_y = cur_y;
            try self.events.append(self.allocator, .{ .pointer = .{ .x = cur_x, .y = cur_y } });
        }
    }

    fn cleanRipples(self: *Runner, current_frame: u32) void {
        var i: usize = 0;
        while (i < self.ripples.items.len) {
            const r = self.ripples.items[i];
            if (current_frame >= r.frame + r.duration) {
                _ = self.ripples.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }
};
