//! Per-refresh JSONL records requested with `--eink-log PATH` (RA8EMU-552).
const std = @import("std");
const Board = @import("ra8_board").board.Board;
const eink = @import("ra8_components").eink;
const refresh = @import("ra8_components").eink.refresh;
const json = @import("report/json/json.zig");

pub const Entry = struct {
    virtual_time_ns: u64,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    waveform: u16,
    full: bool,
};

pub const Run = struct {
    allocator: std.mem.Allocator,
    board: *Board,
    panel: *eink.Panel,
    entries: std.ArrayList(Entry),
    allocation_failed: bool = false,

    pub fn init(allocator: std.mem.Allocator, board: *Board) Run {
        return .{ .allocator = allocator, .board = board, .panel = board.asks.attached_eink orelse &board.panel, .entries = .empty };
    }

    pub fn arm(self: *Run) void {
        self.panel.refresh_log_hook = .{ .context = self, .refreshFn = onRefresh };
    }

    pub fn deinit(self: *Run) void {
        if (self.panel.refresh_log_hook) |hook| {
            if (hook.context == @as(*anyopaque, @ptrCast(self))) self.panel.refresh_log_hook = null;
        }
        self.entries.deinit(self.allocator);
    }

    pub fn write(self: *Run, io: std.Io, path: []const u8) !void {
        if (self.allocation_failed) return error.OutOfMemory;
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        var staging: [4096]u8 = undefined;
        var writer = file.writer(io, &staging);
        for (self.entries.items) |entry| {
            var j = json.over(&writer.interface);
            try j.open(null, '{');
            try j.field("virtual_time_ns", entry.virtual_time_ns);
            try j.field("x", entry.x);
            try j.field("y", entry.y);
            try j.field("width", entry.width);
            try j.field("height", entry.height);
            try j.field("waveform", entry.waveform);
            try j.field("full", entry.full);
            try j.close('}');
            try writer.interface.writeAll("\n");
        }
        try writer.interface.flush();
    }

    pub fn reportJson(self: *const Run, j: anytype) !void {
        try j.open("eink_refreshes_by_mode", '[');
        var i: usize = 0;
        while (i < self.entries.items.len) : (i += 1) {
            const mode = self.entries.items[i].waveform;
            var seen = false;
            for (self.entries.items[0..i]) |prior| if (prior.waveform == mode) {
                seen = true;
                break;
            };
            if (seen) continue;
            var count: u32 = 0;
            for (self.entries.items) |entry| if (entry.waveform == mode) {
                count += 1;
            };
            try j.open(null, '{');
            try j.field("waveform", mode);
            try j.field("count", count);
            try j.close('}');
        }
        try j.close(']');
    }

    pub fn printTotals(self: *const Run, out: anytype) !void {
        var i: usize = 0;
        while (i < self.entries.items.len) : (i += 1) {
            const mode = self.entries.items[i].waveform;
            var seen = false;
            for (self.entries.items[0..i]) |prior| if (prior.waveform == mode) {
                seen = true;
                break;
            };
            if (seen) continue;
            var count: u32 = 0;
            for (self.entries.items) |entry| if (entry.waveform == mode) {
                count += 1;
            };
            try out.print("e-ink refreshes: waveform {d}: {d}\n", .{ mode, count });
        }
    }
};

fn onRefresh(context: *anyopaque, event: refresh.Event) void {
    const self: *Run = @ptrCast(@alignCast(context));
    const geometry = self.panel.planes.geometry;
    self.entries.append(self.allocator, .{
        .virtual_time_ns = self.board.time.base.now(),
        .x = event.x,
        .y = event.y,
        .width = event.width,
        .height = event.height,
        .waveform = event.waveform,
        .full = event.x == 0 and event.y == 0 and event.width == geometry.width and event.height == geometry.height,
    }) catch {
        self.allocation_failed = true;
    };
}
