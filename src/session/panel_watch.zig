//! A viewer's watch on the GLCDC panel (RA8EMU-1126). The GLCDC model
//! composites a frame only when something scans it (glcdc/vsync.zig), so a
//! client subscribed to the panel would never hear of one. While a viewer
//! watches, this arms the panel's frame boundary the way `--frames-out`
//! does: at each boundary it scans the panel into its own buffer, and when
//! the picture differs from the one before, it keeps it and tells the
//! session's event sources what changed. A picture that holds still is
//! scanned and says nothing.
//!
//! The scan is the watch's own, so the model's frame hook is held off while
//! it runs and the event carries the changed box instead of the whole
//! panel. With the last viewer gone the boundary comes off again, and a
//! session nobody watches runs exactly as it did: an in-run scan raises VPOS
//! for the firmware, which is why the model leaves it to a viewer to ask.
//! An e-ink panel reports its own refreshes and needs none of this.
const std = @import("std");
const Board = @import("ra8_board").board.Board;
const Sources = @import("event_sources.zig").Sources;
const session_display = @import("display.zig");
const panel_diff = @import("panel_diff.zig");

pub const Watch = struct {
    allocator: std.mem.Allocator,
    board: *Board,
    /// Where a changed picture is published. Without one the watch only
    /// keeps the picture.
    events: ?*Sources = null,
    /// Viewers watching. The frame boundary is armed while there is one.
    viewers: u32 = 0,
    /// The picture the panel last showed, and the buffer the next scan
    /// lands in.
    kept: []u32 = &.{},
    scratch: []u32 = &.{},
    /// The kept picture's shape; zero until a scan has landed.
    width: u32 = 0,
    height: u32 = 0,
    /// Board time of the scan that last changed the picture.
    changed_ns: u64 = 0,

    pub fn deinit(self: *Watch) void {
        self.disarm();
        self.drop();
    }

    /// One viewer more, or one fewer.
    pub fn set(self: *Watch, on: bool) void {
        if (on) {
            self.viewers += 1;
            if (self.viewers == 1) self.arm();
            return;
        }
        if (self.viewers == 0) return;
        self.viewers -= 1;
        if (self.viewers != 0) return;
        self.disarm();
        self.drop();
    }

    /// The kept picture as an owned grayscale frame, or null when nobody
    /// watches or no scan has landed yet.
    pub fn picture(self: *const Watch, allocator: std.mem.Allocator) !?session_display.Frame {
        if (self.viewers == 0 or self.width == 0) return null;
        const pixels = try allocator.alloc(u8, self.kept.len);
        for (self.kept, pixels) |argb, *gray| gray.* = session_display.grayscale(argb);
        return .{ .width = self.width, .height = self.height, .pixels = pixels, .virtual_ns = self.changed_ns };
    }

    /// Arm the frame boundary from the next board boundary on, unless a
    /// viewer of another kind already scans the panel.
    fn arm(self: *Watch) void {
        const stage = &self.board.display.output;
        if (stage.vsync != null) return;
        stage.vsync = .{ .sink = .{ .context = self, .frame = onFrame }, .next_ns = self.board.time.base.now() };
    }

    fn disarm(self: *Watch) void {
        const stage = &self.board.display.output;
        const armed = stage.vsync orelse return;
        if (armed.sink.frame == onFrame and armed.sink.context == @as(*anyopaque, self)) stage.vsync = null;
    }

    fn drop(self: *Watch) void {
        self.allocator.free(self.kept);
        self.allocator.free(self.scratch);
        self.kept = &.{};
        self.scratch = &.{};
        self.width = 0;
        self.height = 0;
    }

    fn onFrame(context: *anyopaque, when_ns: u64) void {
        const self: *Watch = @ptrCast(@alignCast(context));
        self.scan(when_ns) catch |err| std.debug.print("session: the panel watch lost a frame: {s}\n", .{@errorName(err)});
    }

    /// Scan the panel as the firmware has it now, and publish what changed.
    fn scan(self: *Watch, when_ns: u64) !void {
        const display = &self.board.display;
        const width = display.panelWidth();
        const height = display.panelHeight();
        if (width == 0 or height == 0) return;
        const count = try std.math.mul(usize, width, height);
        if (self.scratch.len != count) {
            self.allocator.free(self.scratch);
            self.scratch = &.{};
            self.scratch = try self.allocator.alloc(u32, count);
        }
        @memset(self.scratch, 0);
        display.output.capture = .{ .pixels = self.scratch, .width = width, .height = height };
        defer display.output.capture = null;
        // The model's frame hook would report this scan as the whole panel.
        const hook = display.event_hook;
        display.event_hook = null;
        defer display.event_hook = hook;
        if (display.scanOut() == null) return;
        const dirty = self.take(width, height) orelse return;
        self.changed_ns = when_ns;
        if (self.events) |events| events.panelChanged(width, height, display.system.frames, dirty);
    }

    /// Make the scanned buffer the kept picture and return what changed:
    /// the whole panel for a first picture or a new shape, null when it is
    /// the picture already kept.
    fn take(self: *Watch, width: u32, height: u32) ?panel_diff.Rect {
        const same_shape = self.width == width and self.height == height;
        const dirty = if (same_shape) panel_diff.box(self.kept, self.scratch, width) orelse return null else panel_diff.whole(width, height);
        std.mem.swap([]u32, &self.kept, &self.scratch);
        self.width = width;
        self.height = height;
        return dirty;
    }
};
