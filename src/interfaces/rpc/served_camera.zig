//! A served session's camera (row 24): opening the host input a camera
//! source names, installing it on the board, and, whenever the session
//! keeps a history, putting the recorded port around it so the frames the
//! firmware captures are recorded and replayed. A pipe, a webcam and the
//! gradient all go through the same port. A change made while the cursor is
//! in the past forks through the session's fork router (`changeCamera`)
//! before it reaches `install`.
const std = @import("std");
const board_camera = @import("ra8_session").board.camera;
const recorded_camera = @import("ra8_session").board.recorded_camera;
const source_spec = @import("ra8_host").camera.source_spec;
const source_open = @import("ra8_host").camera.source_open;
const served_setup = @import("served_setup.zig");

fn recording(self: *served_setup.Served) bool {
    return self.history != null or self.ram_history != null;
}

/// Wraps the board's camera source in the recorded port when the session
/// keeps a history. Call once the history is bound.
pub fn attach(self: *served_setup.Served) !void {
    if (!recording(self)) return;
    try recorded_camera.attach(self.gpa, self.owner.session(), self.owner.board());
}

/// Opens the source `spec` names and makes it the board's camera source.
/// All or nothing: a source that will not open, or cannot be recorded,
/// changes nothing. While the session replays or stands in the past the
/// host is never touched: the recorded change installs a gradient behind
/// the recorded port, which serves every frame from the history, and the
/// port keeps the spec. The run's first live capture opens the source it
/// names (the user's pipe, webcam or file); a source that will not open
/// then is held in the port's `failed`, as a live change reports it, and
/// the gradient keeps serving.
pub fn install(self: *served_setup.Served, spec: source_spec.Spec) !void {
    const session = self.owner.session();
    const board = self.owner.board();
    const muted = session.outputMuted();
    const input = if (muted) null else try source_open.open(self.gpa, self.io, spec);
    var next = try board_camera.source(board, self.gpa, input);
    errdefer next.close();
    if (recording(self)) {
        next = try recorded_camera.wrap(self.gpa, session, next, &board.wire.sensor.format);
        if (muted and spec.kind != .gradient) recorded_camera.from(next).?.later = try keep(self, spec);
    }
    board_camera.set(board, next);
}

/// A spec to open later, with its argument copied.
const Reopen = struct {
    served: *served_setup.Served,
    spec: source_spec.Spec,

    fn open(context: *anyopaque) anyerror!recorded_camera.FrameSource {
        const self: *Reopen = @ptrCast(@alignCast(context));
        const board = self.served.owner.board();
        const input = try source_open.open(self.served.gpa, self.served.io, self.spec);
        const next = try board_camera.source(board, self.served.gpa, input);
        // The status line names the source now serving.
        if (recorded_camera.from(board.capture.source) != null) {
            board.capture.source.label = next.label;
            board.capture.source.detail = next.detail;
        }
        return next;
    }

    fn free(context: *anyopaque) void {
        const self: *Reopen = @ptrCast(@alignCast(context));
        const gpa = self.served.gpa;
        gpa.free(self.spec.arg);
        gpa.destroy(self);
    }
};

fn keep(self: *served_setup.Served, spec: source_spec.Spec) !recorded_camera.Later {
    const copy = try self.gpa.create(Reopen);
    errdefer self.gpa.destroy(copy);
    copy.* = .{ .served = self, .spec = spec };
    copy.spec.arg = try self.gpa.dupe(u8, spec.arg);
    return .{ .context = copy, .openFn = Reopen.open, .freeFn = Reopen.free };
}

/// set_camera_source: with a history on, the change goes through the fork
/// router, which forks when the cursor is before the recorded end.
pub fn set(context: *anyopaque, spec: source_spec.Spec) anyerror!void {
    const self: *served_setup.Served = @ptrCast(@alignCast(context));
    if (self.owner.session().fork_router != null) {
        var buf: [256]u8 = undefined;
        const text = if (spec.arg.len == 0)
            @tagName(spec.kind)
        else
            try std.fmt.bufPrint(&buf, "{s}:{s}", .{ @tagName(spec.kind), spec.arg });
        try self.owner.session().changeCamera(.cpu0, text);
        return;
    }
    try install(self, spec);
}

/// The session's camera hook: the router applies a recorded or live change
/// here, replay included.
pub fn setDirect(context: *anyopaque, spec_text: []const u8) anyerror!void {
    const self: *served_setup.Served = @ptrCast(@alignCast(context));
    try install(self, try source_spec.parse(spec_text));
}
