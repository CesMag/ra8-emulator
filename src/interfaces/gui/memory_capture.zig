//! Reads the memory pane's bytes through the session (RA8EMU-1078), so
//! ui/memory_pane.zig stays a pure draw producer that never imports the
//! session.
const session_api = @import("ra8_session").session_api;
const memory_pane = @import("ui/memory_pane.zig");

/// Reads `row_count` rows (at most `memory_pane.max_rows`) of `core`'s
/// memory from `base` through the session. A row the bus refuses is read again a byte
/// at a time, so a row straddling the end of a region keeps its readable
/// part. Errors that are not about one address, like a core that is not
/// attached, are returned.
pub fn capture(session: *session_api.Session, core: session_api.Core, base: u32, row_count: usize) anyerror!memory_pane.Snapshot {
    var snapshot: memory_pane.Snapshot = .{ .base = base, .count = @min(row_count, memory_pane.max_rows) };
    for (0..snapshot.count) |row| try captureRow(session, core, &snapshot, row);
    return snapshot;
}

fn captureRow(session: *session_api.Session, core: session_api.Core, snapshot: *memory_pane.Snapshot, row: usize) anyerror!void {
    const start = row * memory_pane.per_row;
    session.read(core, snapshot.rowAddress(row), snapshot.bytes[start..][0..memory_pane.per_row]) catch |err| {
        if (!unreadable(err)) return err;
        return captureBytes(session, core, snapshot, row);
    };
    @memset(snapshot.readable[start..][0..memory_pane.per_row], true);
}

fn captureBytes(session: *session_api.Session, core: session_api.Core, snapshot: *memory_pane.Snapshot, row: usize) anyerror!void {
    const start = row * memory_pane.per_row;
    for (0..memory_pane.per_row) |index| {
        const address = snapshot.rowAddress(row) +% @as(u32, @intCast(index));
        session.read(core, address, snapshot.bytes[start + index ..][0..1]) catch |err| {
            if (unreadable(err)) continue;
            return err;
        };
        snapshot.readable[start + index] = true;
    }
}

/// The bus errors that mean this address cannot be read.
fn unreadable(err: anyerror) bool {
    return err == error.Unmapped or err == error.SecurityViolation;
}
