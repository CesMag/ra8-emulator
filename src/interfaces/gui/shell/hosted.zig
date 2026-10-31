//! The per-user listener and the session it serves (RA8EMU-1156): outside
//! clients (ctl, IDEs) reach the same in-process session, and a second
//! launch focuses this window. The listener must stay put once the shell
//! holds it, so it lives here whole.
const std = @import("std");
const platform = @import("../platform.zig");
const shell_loop = @import("loop.zig");
const local_session = @import("../local_session.zig");
const session_link = @import("../session_link.zig");
const session_api = @import("ra8_session").api;
const host_listener = @import("ra8_rpc").host_listener;
const served_server = @import("ra8_rpc").session.server;
const proto = @import("ra8_rpc").session.rpc;

const Env = proto.Client.Env;

/// The per-user listener and the session it serves (RA8EMU-1156).
pub const Hosted = struct {
    listener: host_listener.Listener,
    context: *served_server.Context,
    window: platform.Platform,
    tx: []u8,
    gpa: std.mem.Allocator,
    /// A second launch asked for the window: the shell's thread raises it,
    /// whichever thread answers the listener.
    raise: std.atomic.Value(bool) = .init(false),

    pub fn rebind(self: *Hosted, context: *served_server.Context) void {
        self.context = context;
        context.transport_async = true;
    }

    /// List the one session and its gdb port in the discovery file.
    pub fn announce(self: *Hosted, elf: []const u8, live: ?*session_api.Session) void {
        _ = self.listener.addGdb(elf, live) catch return;
        self.listener.announce() catch {};
    }

    fn answer(self: *Hosted) !void {
        if (self.listener.takeFocus()) self.raise.store(true, .release);
        self.listener.pumpGdb();
        return self.listener.answer(self.context, self.tx);
    }

    pub fn deinit(self: *Hosted) void {
        self.listener.deinit();
        self.gpa.free(self.tx);
    }
};

pub fn answerHosted(context: *anyopaque) anyerror!void {
    const hosted: *Hosted = @ptrCast(@alignCast(context));
    return hosted.answer();
}

/// Binds the per-user host listener onto `hosted`; without one the shell
/// answers only its own session (RA8EMU-1156).
pub fn bindHosted(hosted: *?Hosted, allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, window: platform.Platform, elf: []const u8, session: *local_session.LocalSession, link: *session_link.Link, shell: *shell_loop.Shell) void {
    shell.link = link;
    const bound = host_listener.Listener.bind(allocator, io, env) catch return;
    const tx = allocator.alloc(u8, Env.max_frame) catch return;
    hosted.* = .{ .listener = bound, .context = &session.setup.context, .window = window, .tx = tx, .gpa = allocator };
    // The frame loop owns the pump here, so this host's clients speak the
    // queued advance contract: advance_async plus the transport topic
    // (RA8EMU-1196, slice 14). `serve` keeps the blocking contract.
    session.setup.context.transport_async = true;
    const held = &hosted.*.?;
    held.announce(elf, session.setup.owner.session());
    shell.listener = .{ .context = held, .answerFn = answerHosted };
    shell.raise = &held.raise;
}
