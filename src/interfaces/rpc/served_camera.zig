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
/// A source that will not open changes nothing.
pub fn install(self: *served_setup.Served, spec: source_spec.Spec) !void {
    const input = try source_open.open(self.gpa, self.io, spec);
    try board_camera.install(self.owner.board(), self.gpa, input);
    try attach(self);
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
