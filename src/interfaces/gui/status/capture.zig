//! Reads the session's status into the status strip's view (RA8EMU-1085):
//! the dot's tone and the status line. ui/status_strip.zig draws the result
//! without importing the session model or the link.
const status_bar = @import("bar.zig");
const session_link = @import("../session_link.zig");
const status_strip = @import("../ui/status_strip.zig");

/// The worst news wins: a failure or refusal, then the run state.
pub fn tone(status: *const status_bar.Status, state: session_link.State) status_strip.Tone {
    switch (state) {
        .failed => return .bad,
        .connecting, .closed => return .waiting,
        .connected => {},
    }
    if (status.refused != null) return .bad;
    return switch (status.run) {
        .unknown => .good,
        .running => .running,
        .halted => .halted,
    };
}

/// The strip for `status` over a link in `state`.
pub fn strip(status: *const status_bar.Status, state: session_link.State) status_strip.Strip {
    var view: status_strip.Strip = .{ .tone = tone(status, state) };
    const line = status.text(state, &view.line_buf) catch view.line_buf[0..];
    view.line_len = line.len;
    return view;
}
