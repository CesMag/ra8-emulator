//! The startup of a fresh served history session: open the cache root,
//! then run the host's existing safe sweep once so stale ephemeral
//! sessions an earlier crashed run left are cleared (src/host/stops.zig
//! promises it). Only a fresh start sweeps. A reopen, a read-only
//! maintenance command and a failed admission never reach this file.
const std = @import("std");
const history = @import("ra8_host").history;

/// Open the cache root for a fresh session and sweep it. The sweep is
/// checked before creating the new session, and it protects
/// kept, live, foreign, unmarked and young-draft entries by its own policy.
pub fn openFresh(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !history.base.Base {
    var base = try history.base.Base.openConfigured(allocator, io, path, .cache, .{});
    errdefer base.close();
    const report = try history.sweep.run(&base, .{}, null);
    if (report.failed != 0) return error.HistoryCleanupFailed;
    return base;
}
