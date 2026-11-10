//! Optional per-user RPC/GDB discovery owned by the headless daemon.
const std = @import("std");
const Listener = @import("ra8_rpc").host_listener.Listener;
const Session = @import("ra8_session").api.Session;

/// Bind and announce one served session. The caller keeps the returned listener
/// alive and pumps it beside the primary transport until that transport exits.
pub fn open(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, elf: []const u8, session: *Session) !Listener {
    var listener = try Listener.bind(gpa, io, env);
    errdefer listener.deinit();
    _ = try listener.addGdb(elf, session);
    try listener.announce();
    return listener;
}
