//! The recorded camera port (row 24): a FrameSource that wraps whatever
//! host input the camera has (a pipe, a webcam, the gradient) so the frames
//! the firmware captured are part of the history.
//!
//! Live, each capture the CEU arms pulls the whole frame from the wrapped
//! source, records it as a `camera_frame` boundary at the capture's
//! position, and serves the CEU from that copy. Replaying, or playing along
//! a line before its recorded end, the frame comes from the history's
//! feeder at the same position and the wrapped source is never touched. A
//! replayed capture with no frame recorded for it is a determinism error:
//! the guest gets a blank frame, `failed` holds the error, and the host
//! source is not read as a stand-in.
const std = @import("std");
const frame_source = @import("ra8_chip").periph.frame_source;
const hosted = @import("ra8_components").camera.hosted;
const Board = @import("ra8_board").board.Board;
const camera_frame = @import("../history/camera_frame.zig");
const api = @import("../api.zig");
const line = @import("../line.zig");

pub const Error = error{
    /// A replayed capture found no frame recorded at its position.
    UnrecordedCapture,
    /// The recorded frame's geometry is not the one the CEU asked for.
    GeometryMismatch,
};

pub const RecordedCamera = struct {
    gpa: std.mem.Allocator,
    inner: frame_source.FrameSource,
    session: *api.Session,
    /// The sensor's FORMAT CONTROL byte, stamped into each record.
    format_control: *const u8,
    /// The current capture's bytes, line after line.
    pixels: std.ArrayList(u8) = .empty,
    width: u32 = 0,
    /// The first error a capture hit; the application reads it.
    failed: ?anyerror = null,
    /// How many frames were served from the history, for a caller that
    /// shows or checks that a replay read nothing from the host.
    replayed: u64 = 0,

    fn replaying(self: *const RecordedCamera) bool {
        return self.session.replaying or line.inPast(self.session);
    }

    fn note(self: *RecordedCamera, err: anyerror) void {
        if (self.failed == null) self.failed = err;
        if (self.replaying()) self.session.failReplay(.camera, err);
    }

    fn frame(context: *anyopaque, when: u64, shape: frame_source.Shape) void {
        const self: *RecordedCamera = @ptrCast(@alignCast(context));
        self.width = shape.width;
        self.pixels.clearRetainingCapacity();
        self.pixels.resize(self.gpa, @as(usize, shape.width) * shape.lines) catch |err| {
            self.pixels.clearRetainingCapacity();
            return self.note(err);
        };
        @memset(self.pixels.items, 0);
        if (self.replaying()) {
            self.replay(shape) catch |err| self.note(err);
        } else {
            self.capture(when, shape) catch |err| self.note(err);
        }
    }

    fn replay(self: *RecordedCamera, shape: frame_source.Shape) !void {
        const feeder = if (self.session.replay_feeder) |*f| f else return Error.UnrecordedCapture;
        const body = feeder.takeFrame(self.session.currentPosition()) orelse return Error.UnrecordedCapture;
        var decoded: std.ArrayList(u8) = .empty;
        defer decoded.deinit(self.gpa);
        const meta = try camera_frame.decode(self.gpa, body, &decoded);
        if (meta.width != shape.width or meta.lines != shape.lines) return Error.GeometryMismatch;
        @memcpy(self.pixels.items, decoded.items);
        self.replayed += 1;
    }

    fn capture(self: *RecordedCamera, when: u64, shape: frame_source.Shape) !void {
        self.inner.frame(when, shape);
        var row: u32 = 0;
        while (row < shape.lines) : (row += 1) {
            const at = @as(usize, row) * shape.width;
            self.inner.fill(row, 0, self.pixels.items[at..][0..shape.width]);
        }
        const history = self.session.history orelse return;
        if (history.recorder == null) return;
        var body: std.Io.Writer.Allocating = .init(self.gpa);
        defer body.deinit();
        try camera_frame.encode(self.gpa, &body.writer, .{
            .width = shape.width,
            .lines = shape.lines,
            .format = if (hosted.formatFor(self.format_control.*) == .rgb565) .rgb565 else .yuv422,
        }, self.pixels.items);
        try history.recordLanding(self.session.currentPosition(), .camera_frame, body.written());
    }

    fn fill(context: *anyopaque, row: u32, column: u32, out: []u8) void {
        const self: *RecordedCamera = @ptrCast(@alignCast(context));
        const start = @as(usize, row) * self.width + column;
        const have = if (start < self.pixels.items.len) self.pixels.items.len - start else 0;
        const n = @min(out.len, have);
        @memcpy(out[0..n], self.pixels.items[start..][0..n]);
        @memset(out[n..], 0);
    }

    fn close(context: *anyopaque) void {
        const self: *RecordedCamera = @ptrCast(@alignCast(context));
        self.inner.close();
        self.pixels.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    fn preview(context: *anyopaque) ?frame_source.Preview {
        const self: *RecordedCamera = @ptrCast(@alignCast(context));
        // The preview is the GUI's own look, off the engine thread, so it
        // checks only the replay flag: whether the cursor is in the past
        // takes the history's graph, which only the engine thread may read.
        // While the cursor is in the past the host source is still read
        // for the preview alone; the guest never sees it and no frame is
        // recorded from it.
        if (self.session.replaying) return null;
        return self.inner.preview();
    }

    const vtable = frame_source.FrameSource.VTable{
        .frame = frame,
        .fill = fill,
        .close = close,
        .preview = preview,
    };
};

/// `source` wrapped in the recorded port. The port owns `source` from here;
/// on an error the caller still does.
pub fn wrap(gpa: std.mem.Allocator, session: *api.Session, source: frame_source.FrameSource, format_control: *const u8) !frame_source.FrameSource {
    if (from(source) != null) return source;
    const self = try gpa.create(RecordedCamera);
    self.* = .{ .gpa = gpa, .inner = source, .session = session, .format_control = format_control };
    return .{ .context = self, .vtable = &RecordedCamera.vtable, .label = source.label, .detail = source.detail };
}

/// The recorded port inside `source`, or null for any other source.
pub fn from(source: frame_source.FrameSource) ?*RecordedCamera {
    if (source.vtable != &RecordedCamera.vtable) return null;
    return @ptrCast(@alignCast(source.context));
}

/// Puts the recorded port around `board`'s current camera source, whatever
/// it is. A source already recorded stays as it is. Call it on the thread
/// that steps the board.
pub fn attach(gpa: std.mem.Allocator, session: *api.Session, board: *Board) !void {
    board.capture.source = try wrap(gpa, session, board.capture.source, &board.wire.sensor.format);
}
