//! Reads the registers pane's values through the session (RA8EMU-1078).
//! The pane (ui/registers_pane.zig) names its registers as text so gui/ui
//! never imports the session; `shown` turns each name into the session's
//! Register at comptime, so a name the session does not know fails the
//! build.
const session_api = @import("ra8_session").api;
const registers_pane = @import("ui/registers_pane.zig");

const Register = session_api.Register;

/// The session register behind each of the pane's names, in its order.
pub const shown: [registers_pane.names.len]Register = blk: {
    var out: [registers_pane.names.len]Register = undefined;
    for (registers_pane.names, 0..) |name, index| out[index] = @field(Register, name);
    break :blk out;
};

/// Reads every shown register of `core` through the session.
pub fn capture(session: *session_api.Session, core: session_api.Core) anyerror!registers_pane.Snapshot {
    var snapshot: registers_pane.Snapshot = .{ .mve = registers_pane.hasMve(core) };
    for (shown, 0..) |which, index| {
        if (which == .vpr and !snapshot.mve) continue;
        snapshot.values[index] = try session.register(core, which);
    }
    return snapshot;
}
