//! Numbered P6 frames for `--frames-out`. GLCDC frames arrive after scans;
//! e-ink frames arrive after glass refreshes. Sampling and duplicate
//! suppression are shared, and frames.txt records emulated time in ns.
const std = @import("std");
const Board = @import("ra8_board").board.Board;
const frame_args = @import("frames_args.zig");
const eink = @import("ra8_components").eink;
const eink_wire = @import("ra8_components").eink_wire;
const gif_out = @import("gif_out.zig");
const video_out = @import("video_out.zig");
const display_settled = @import("ra8_board").display_settled;

pub const Sequence = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    owns_directory: bool,
    index: ?std.Io.File,
    gif_path: ?[]const u8,
    gif_writer: ?gif_out.Writer = null,
    video_writer: ?video_out.Writer = null,
    every: usize,
    scanned: usize = 0,
    written: usize = 0,
    previous: ?[]u32 = null,
    previous_width: u32 = 0,
    previous_height: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8, every: usize) !Sequence {
        return initOutputs(allocator, io, path, null, every);
    }

    pub fn initOutputs(allocator: std.mem.Allocator, io: std.Io, frames_path: ?[]const u8, gif_path: ?[]const u8, every: usize) !Sequence {
        return initAll(allocator, io, frames_path, gif_path, null, every);
    }

    pub fn initAll(allocator: std.mem.Allocator, io: std.Io, frames_path: ?[]const u8, gif_path: ?[]const u8, video_path: ?[]const u8, every: usize) !Sequence {
        if (every == 0) return error.BadInterval;
        if (frames_path == null and gif_path == null and video_path == null) return error.NoOutput;
        var directory = std.Io.Dir.cwd();
        var owns_directory = false;
        var index: ?std.Io.File = null;
        errdefer if (owns_directory) directory.close(io);
        if (frames_path) |path| {
            try std.Io.Dir.cwd().createDirPath(io, path);
            directory = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
            owns_directory = true;
            var entries = directory.iterate();
            while (try entries.next(io)) |entry| {
                if (isFrameName(entry.name)) try directory.deleteFile(io, entry.name);
            }
            index = try directory.createFile(io, "frames.txt", .{});
        }
        const video_writer = if (video_path) |path| try video_out.Writer.init(allocator, io, path) else null;
        return .{
            .allocator = allocator,
            .io = io,
            .directory = directory,
            .owns_directory = owns_directory,
            .index = index,
            .gif_path = gif_path,
            .video_writer = video_writer,
            .every = every,
        };
    }

    fn isFrameName(name: []const u8) bool {
        if (name.len != 15 or !std.mem.startsWith(u8, name, "frame_") or !std.mem.endsWith(u8, name, ".ppm")) return false;
        for (name[6..11]) |digit| if (!std.ascii.isDigit(digit)) return false;
        return true;
    }

    pub fn deinit(self: *Sequence) void {
        if (self.previous) |pixels| self.allocator.free(pixels);
        if (self.gif_writer) |*writer| writer.deinit();
        if (self.video_writer) |*writer| writer.deinit();
        if (self.index) |file| file.close(self.io);
        if (self.owns_directory) self.directory.close(self.io);
    }

    /// Record one complete ARGB8888 panel. Every Nth scan is considered,
    /// and scans identical to their immediate predecessor are suppressed.
    fn sameImage(previous: []const u32, current: []const u32) bool {
        if (previous.len != current.len) return false;
        for (previous, current) |before, after| {
            if (before & 0x00FF_FFFF != after & 0x00FF_FFFF) return false;
        }
        return true;
    }

    /// `when` is the emulated time of the scan, written to frames.txt.
    pub fn record(self: *Sequence, width: u32, height: u32, pixels: []const u32, when: u64) !void {
        const count = std.math.mul(usize, width, height) catch return error.BadShape;
        if (width == 0 or height == 0 or pixels.len != count) return error.BadShape;
        const same = if (self.previous) |previous|
            self.previous_width == width and self.previous_height == height and
                sameImage(previous, pixels)
        else
            false;
        if (self.previous) |previous| {
            if (previous.len != pixels.len) {
                self.allocator.free(previous);
                self.previous = null;
            }
        }
        if (self.previous == null) self.previous = try self.allocator.alloc(u32, pixels.len);
        @memcpy(self.previous.?, pixels);
        self.previous_width = width;
        self.previous_height = height;

        const index = self.scanned;
        self.scanned += 1;
        if (same or index % self.every != 0) return;
        if (self.gif_path) |path| {
            if (self.gif_writer == null) self.gif_writer = try gif_out.Writer.init(self.allocator, self.io, path, width, height);
            try self.gif_writer.?.record(width, height, pixels, when);
        }
        if (self.index != null) {
            try self.write(width, height, pixels);
            var line: [64]u8 = undefined;
            const text = try std.fmt.bufPrint(&line, "frame_{d:0>5}.ppm {d}\n", .{ self.written, when });
            try self.index.?.writeStreamingAll(self.io, text);
        }
        self.written += 1;
    }

    pub fn recordVideo(self: *Sequence, width: u32, height: u32, pixels: []const u32, when: u64) !void {
        if (self.video_writer) |*writer| try writer.record(width, height, pixels, when);
    }

    pub fn holdVideoUntil(self: *Sequence, when: u64) !void {
        if (self.video_writer) |*writer| try writer.holdUntil(when);
    }

    pub fn finish(self: *Sequence) !void {
        if (self.gif_writer) |*writer| try writer.finish();
        if (self.video_writer) |*writer| try writer.finish();
    }

    fn write(self: *Sequence, width: u32, height: u32, pixels: []const u32) !void {
        const name = try std.fmt.allocPrint(self.allocator, "frame_{d:0>5}.ppm", .{self.written});
        defer self.allocator.free(name);
        var file = try self.directory.createFile(self.io, name, .{});
        defer file.close(self.io);
        var buffer: [4096]u8 = undefined;
        var buffered = file.writerStreaming(self.io, &buffer);
        const out = &buffered.interface;
        try out.print("P6\n{d} {d}\n255\n", .{ width, height });
        for (pixels) |pixel| {
            try out.writeByte(@truncate(pixel >> 16));
            try out.writeByte(@truncate(pixel >> 8));
            try out.writeByte(@truncate(pixel));
        }
        try out.flush();
    }
};

pub const FrameCapture = @import("ra8_board").frame_capture.FrameCapture;

/// --frames-out armed before the run (RA8EMU-573). It installs a Vsync on
/// the GLCDC output stage, so each frame period the board boundary scans the
/// panel and the frame is kept with its emulated time. The end-of-run report
/// scan is kept too, unless it repeats the last frame.
pub const Armed = struct {
    allocator: std.mem.Allocator,
    board: *Board,
    sequence: Sequence,
    capture: ?FrameCapture = null,
    /// The first error an in-run frame hit; the boundary cannot return one.
    failed: ?anyerror = null,
    eink_panel: ?*eink.Panel = null,
    eink_pixels: ?[]u32 = null,
    /// Frames kept from each source: the GLCDC, or the board's own e-ink
    /// panel when no --attach panel was asked for (RA8EMU-591). The first
    /// source to give a frame owns the sequence.
    glcdc_frames: u32 = 0,
    board_eink_frames: u32 = 0,
    settle_only: bool = false,
    settled: display_settled.Detector,
    settle_sequence: ?Sequence = null,

    /// Null when both sequence outputs are off. Call after board.attach:
    /// attaching the GLCDC rebuilds its output stage, which would drop Vsync.
    pub fn arm(allocator: std.mem.Allocator, io: std.Io, board: *Board, path: ?[]const u8, every: usize) !?*Armed {
        return armOutputs(allocator, io, board, path, null, every);
    }

    pub fn armOutputs(allocator: std.mem.Allocator, io: std.Io, board: *Board, frames_path: ?[]const u8, gif_path: ?[]const u8, every: usize) !?*Armed {
        return armAll(allocator, io, board, frames_path, gif_path, null, every);
    }

    fn armAll(allocator: std.mem.Allocator, io: std.Io, board: *Board, frames_path: ?[]const u8, gif_path: ?[]const u8, video_path: ?[]const u8, every: usize) !?*Armed {
        if (frames_path == null and gif_path == null and video_path == null) return null;
        const self = try allocator.create(Armed);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .board = board,
            .sequence = try Sequence.initAll(allocator, io, frames_path, gif_path, video_path, every),
            .settled = .{ .allocator = allocator },
        };
        errdefer self.sequence.deinit();
        if (board.asks.attached_eink) |panel| {
            self.eink_panel = panel;
            self.eink_pixels = try allocator.alloc(u32, panel.planes.geometry.pixels());
            panel.refresh_hook = .{ .context = self, .refreshFn = onEinkRefresh };
        } else if (board.panel.refresh_hook == null) {
            board.panel.refresh_hook = .{ .context = self, .refreshFn = onEinkRefresh };
        }
        board.display.output.vsync = .{ .sink = .{ .context = self, .frame = onFrame, .settle = onSettle } };
        return self;
    }

    pub fn armForCli(allocator: std.mem.Allocator, io: std.Io, board: *Board, options: frame_args.Options) !?*Armed {
        const path = options.frames_out orelse if (options.frame_on_settle != null and options.gif_out == null) options.frame_on_settle else null;
        const armed = try armAll(allocator, io, board, path, options.gif_out, options.video_out, options.frames_every) orelse return null;
        if (options.frame_on_settle != null and (options.frames_out != null or options.gif_out != null))
            armed.settle_sequence = try Sequence.init(allocator, io, options.frame_on_settle.?, options.frames_every);
        if (options.frame_on_settle != null or options.video_out != null) {
            armed.settle_only = options.frames_out == null and options.gif_out == null;
            armed.settled.window_ns = options.settle_window_ns;
            armed.settled.eink_settled = (armed.eink_panel orelse &board.panel).film.settled;
        }
        return armed;
    }

    /// The run armed on this board, if any.
    pub fn of(board: *Board) ?*Armed {
        const vsync = board.display.output.vsync orelse return null;
        if (vsync.sink.frame != onFrame) return null;
        return @ptrCast(@alignCast(vsync.sink.context));
    }

    fn onSettle(context: *anyopaque, now: u64) anyerror!void {
        const self: *Armed = @ptrCast(@alignCast(context));
        try self.pollSettle(now);
    }

    fn onFrame(context: *anyopaque, when: u64) void {
        const self: *Armed = @ptrCast(@alignCast(context));
        self.frameAt(when) catch |err| {
            if (self.failed == null) self.failed = err;
        };
    }

    fn frameAt(self: *Armed, when: u64) !void {
        const capture = (try self.fit()) orelse return;
        if (self.board.display.scanOut() == null) return;
        const tracks_settle = self.settle_only or self.settle_sequence != null or self.sequence.video_writer != null;
        if (tracks_settle and try self.settled.observeFrame(capture.width, capture.height, capture.pixels, when)) {
            if (self.settle_sequence) |*sequence| try sequence.record(capture.width, capture.height, capture.pixels, when);
            if (self.settle_only) try self.sequence.record(capture.width, capture.height, capture.pixels, when);
            try self.sequence.recordVideo(capture.width, capture.height, capture.pixels, when);
        }
        if (!self.settle_only) try self.sequence.record(capture.width, capture.height, capture.pixels, when);
        self.glcdc_frames += 1;
        capture.before = self.board.display.system.frames;
    }

    /// A scanned GLCDC frame: written once it has held unchanged for the
    /// settle window, and not again until the picture changes.
    pub fn observeFrame(self: *Armed, width: u32, height: u32, pixels: []const u32, when: u64) !void {
        if (try self.settled.observeFrame(width, height, pixels, when))
            try self.sequence.record(width, height, pixels, when);
    }

    /// Poll from each virtual-time boundary. The e-ink controller's LUT
    /// status is authoritative; GLCDC stability is sampled at its vsyncs.
    pub fn pollSettle(self: *Armed, now: u64) !void {
        if (!self.settle_only and self.settle_sequence == null and self.sequence.video_writer == null) return;
        const panel = self.eink_panel orelse &self.board.panel;
        if (!self.settled.observeEink(panel)) return;
        const count = panel.planes.glass.pixels.len;
        if (count == 0) return;
        if (self.eink_pixels == null or self.eink_pixels.?.len != count) {
            if (self.eink_pixels) |old| self.allocator.free(old);
            self.eink_pixels = try self.allocator.alloc(u32, count);
        }
        for (panel.planes.glass.pixels, self.eink_pixels.?) |gray, *pixel| {
            pixel.* = 0xFF00_0000 | (@as(u32, gray) << 16) | (@as(u32, gray) << 8) | gray;
        }
        if (self.settle_sequence) |*sequence| try sequence.record(panel.planes.geometry.width, panel.planes.geometry.height, self.eink_pixels.?, now);
        if (self.settle_only) try self.sequence.record(panel.planes.geometry.width, panel.planes.geometry.height, self.eink_pixels.?, now);
        try self.sequence.recordVideo(panel.planes.geometry.width, panel.planes.geometry.height, self.eink_pixels.?, now);
    }

    fn onEinkRefresh(context: *anyopaque) void {
        const self: *Armed = @ptrCast(@alignCast(context));
        if (self.settle_only) return;
        const panel = self.eink_panel orelse board: {
            if (self.glcdc_frames != 0) return;
            break :board &self.board.panel;
        };
        if (self.eink_pixels == null) self.eink_pixels = self.allocator.alloc(u32, panel.planes.geometry.pixels()) catch |err| {
            if (self.failed == null) self.failed = err;
            return;
        };
        const pixels = self.eink_pixels.?;
        if (panel.planes.glass.pixels.len != pixels.len) return;
        for (panel.planes.glass.pixels, pixels) |gray, *pixel| {
            pixel.* = 0xFF00_0000 | (@as(u32, gray) << 16) | (@as(u32, gray) << 8) | gray;
        }
        self.sequence.record(panel.planes.geometry.width, panel.planes.geometry.height, pixels, self.board.time.base.now()) catch |err| {
            if (self.failed == null) self.failed = err;
        };
        if (self.eink_panel == null) self.board_eink_frames += 1;
    }

    /// The capture buffer, sized to the panel as the firmware has it now.
    pub fn fit(self: *Armed) !?*FrameCapture {
        if (self.eink_panel != null or self.board_eink_frames != 0) return null;
        if (self.capture) |*capture| {
            const same = capture.width == self.board.display.panelWidth() and
                capture.height == self.board.display.panelHeight();
            if (same) {
                self.board.display.output.capture = .{ .pixels = capture.pixels, .width = capture.width, .height = capture.height };
                return capture;
            }
            capture.deinit(self.board);
            self.capture = null;
        }
        self.capture = try FrameCapture.init(self.allocator, self.board);
        return if (self.capture) |*capture| capture else null;
    }

    pub fn finish(self: *Armed) !void {
        if (self.failed) |err| return err;
        if (!self.settle_only) {
            if (self.capture) |*capture| {
                if (self.board_eink_frames == 0) try capture.finish(self.board, &self.sequence);
            }
        }
        try self.sequence.holdVideoUntil(self.board.time.base.now());
        try self.sequence.finish();
        if (self.settle_sequence) |*sequence| try sequence.finish();
    }

    pub fn deinit(self: *Armed) void {
        self.board.display.output.vsync = null;
        const hooked = self.eink_panel orelse &self.board.panel;
        if (hooked.refresh_hook) |hook| {
            if (hook.context == @as(*anyopaque, @ptrCast(self))) hooked.refresh_hook = null;
        }
        if (self.eink_pixels) |pixels| self.allocator.free(pixels);
        self.settled.deinit();
        if (self.capture) |*capture| capture.deinit(self.board);
        self.sequence.deinit();
        if (self.settle_sequence) |*sequence| sequence.deinit();
        self.allocator.destroy(self);
    }
};

/// Report-side handle for an already armed frame sequence.
pub const Run = struct {
    armed: ?*Armed,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, board: *Board, path: ?[]const u8, every: usize) !Run {
        const armed = Armed.of(board) orelse try Armed.arm(allocator, io, board, path, every) orelse return .{ .armed = null };
        _ = try armed.fit();
        return .{ .armed = armed };
    }

    pub fn initForCli(allocator: std.mem.Allocator, io: std.Io, board: *Board, options: frame_args.Options) !Run {
        const armed = Armed.of(board) orelse try Armed.armForCli(allocator, io, board, options) orelse return .{ .armed = null };
        _ = try armed.fit();
        return .{ .armed = armed };
    }

    pub fn finish(self: *Run, board: *Board) !void {
        _ = board;
        if (self.armed) |armed| try armed.finish();
    }

    pub fn deinit(self: *Run, board: *Board) void {
        _ = board;
        if (self.armed) |armed| armed.deinit();
    }
};
