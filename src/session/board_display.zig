//! Session access to the board's raw panel frame and settled state.
const std = @import("std");
const Board = @import("ra8_board").board.Board;
const display_settled = @import("ra8_board").display_settled;
const FrameCapture = @import("ra8_board").frame_capture.FrameCapture;
const eink = @import("ra8_components").eink;
const session_display = @import("display.zig");
const panel_watch = @import("panel_watch.zig");

pub const Error = error{ Timeout, NoVirtualProgress, NoFrame };

pub const Advance = struct {
    context: *anyopaque,
    advanceFn: *const fn (*anyopaque, max_ns: u64) anyerror!void,
};

/// Adapts a Board and its run loop to the core-addressed Session API.
pub const Host = struct {
    allocator: std.mem.Allocator,
    board: *Board,
    advance: Advance,
    quantum_ns: u64 = 16_666_667,
    settled: display_settled.Detector,
    /// The GLCDC panel as a subscribed viewer sees it (RA8EMU-1126).
    watch: panel_watch.Watch,

    pub fn init(allocator: std.mem.Allocator, board: *Board, advance: Advance) Host {
        const panel = einkPanel(board);
        return .{
            .allocator = allocator,
            .board = board,
            .advance = advance,
            .settled = .{
                .allocator = allocator,
                .eink_settled = if (panel) |found| found.film.settled else 0,
            },
            .watch = .{ .allocator = allocator, .board = board },
        };
    }

    pub fn deinit(self: *Host) void {
        self.watch.deinit();
        self.settled.deinit();
    }

    pub fn interface(self: *Host) session_display.Display {
        return .{
            .context = self,
            .waitSettledFn = waitSettledThunk,
            .frameFn = frameThunk,
            .watchFn = watchThunk,
        };
    }

    fn watchThunk(context: *anyopaque, on: bool) void {
        const self: *Host = @ptrCast(@alignCast(context));
        self.watch.set(on);
    }

    fn waitSettledThunk(context: *anyopaque, timeout_ns: u64) anyerror!void {
        const self: *Host = @ptrCast(@alignCast(context));
        return self.waitSettled(timeout_ns);
    }

    fn frameThunk(context: *anyopaque, allocator: std.mem.Allocator) anyerror!session_display.Frame {
        const self: *Host = @ptrCast(@alignCast(context));
        return self.frame(allocator);
    }

    pub fn waitSettled(self: *Host, timeout_ns: u64) !void {
        const started = self.board.time.base.now();
        self.settled.resetWait();
        while (true) {
            if (einkPanel(self.board)) |panel| return self.waitEink(panel, started, timeout_ns);
            if (try FrameCapture.init(self.allocator, self.board)) |capture_value| {
                var capture = capture_value;
                capture.deinit(self.board);
                return self.waitGlcdc(started, timeout_ns);
            }
            const now = self.board.time.base.now();
            const elapsed = now -| started;
            if (elapsed >= timeout_ns) return Error.Timeout;
            try self.advanceOne(@min(self.quantum_ns, timeout_ns - elapsed), now);
        }
    }

    fn waitEink(self: *Host, panel: *eink.Panel, started: u64, timeout_ns: u64) !void {
        while (true) {
            if (self.settled.observeEink(panel)) return;
            const now = self.board.time.base.now();
            const elapsed = now -| started;
            if (elapsed >= timeout_ns) return Error.Timeout;
            try self.advanceOne(@min(self.quantum_ns, timeout_ns - elapsed), now);
        }
    }

    fn waitGlcdc(self: *Host, started: u64, timeout_ns: u64) !void {
        var capture = (try FrameCapture.init(self.allocator, self.board)) orelse return Error.NoFrame;
        defer capture.deinit(self.board);
        while (true) {
            const now = self.board.time.base.now();
            if (self.board.display.scanOut() != null and
                try self.settled.observeFrame(capture.width, capture.height, capture.pixels, now)) return;
            const elapsed = now -| started;
            if (elapsed >= timeout_ns) return Error.Timeout;
            try self.advanceOne(@min(self.quantum_ns, timeout_ns - elapsed), now);
        }
    }

    fn advanceOne(self: *Host, amount_ns: u64, before: u64) !void {
        if (amount_ns == 0) return Error.Timeout;
        try self.advance.advanceFn(self.advance.context, amount_ns);
        if (self.board.time.base.now() <= before) return Error.NoVirtualProgress;
    }

    pub fn frame(self: *Host, allocator: std.mem.Allocator) !session_display.Frame {
        if (einkPanel(self.board)) |panel| {
            const pixels = panel.planes.glass.pixels;
            if (pixels.len == 0) return Error.NoFrame;
            return .{
                .width = panel.planes.geometry.width,
                .height = panel.planes.geometry.height,
                .pixels = try allocator.dupe(u8, pixels),
                .virtual_ns = self.board.time.base.now(),
            };
        }
        // A watched panel is scanned at its frame boundaries: hand out that
        // picture, since a scan here would be one more frame for the firmware.
        if (try self.watch.picture(allocator)) |kept| return kept;
        var capture = (try FrameCapture.init(self.allocator, self.board)) orelse return Error.NoFrame;
        defer capture.deinit(self.board);
        if (self.board.display.scanOut() == null) return Error.NoFrame;
        const pixels = try allocator.alloc(u8, capture.pixels.len);
        errdefer allocator.free(pixels);
        for (capture.pixels, pixels) |argb, *gray| gray.* = session_display.grayscale(argb);
        return .{
            .width = capture.width,
            .height = capture.height,
            .pixels = pixels,
            .virtual_ns = self.board.time.base.now(),
        };
    }
};

fn einkPanel(board: *Board) ?*eink.Panel {
    if (board.asks.attached_eink) |panel| return panel;
    if (board.panel.planes.image.pixels.len != 0) return &board.panel;
    return null;
}
