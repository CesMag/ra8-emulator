//! The launcher's rebuild for a board-profile choice (RA8EMU-1152): the
//! local session is reopened in place with the same ELF and the chosen
//! profile, which comes up paused at reset, the link and the served
//! session are rebound, the host listener re-announces, the run-to marks
//! drop (the rebuilt session's breakpoint ids are gone), and the drive
//! loop reloads the image once the rebuilt session greets again.
const std = @import("std");
const session_link = @import("../session_link.zig");
const local_session = @import("../local_session.zig");
const shell_loop = @import("loop.zig");
const session_worker = @import("../session_worker.zig");
const shell_hosted = @import("hosted.zig");
const shell_pick = @import("board_pick.zig");
const board_profiles = @import("board_profiles.zig");
const board_store = @import("board_store.zig");

/// Builds the Board menu's pick and its rebuild on `allocator` (main's
/// arena), wires them to each other, serves `session` to the shell, and
/// brings the saved choice back, the status line naming the machine in
/// force. Null only when out of memory: the shell then has no Board menu.
pub fn launch(allocator: std.mem.Allocator, io: std.Io, image: []const u8, apps: []const []const u8, session: *local_session.LocalSession, shell: *shell_loop.Shell, hosted: *?shell_hosted.Hosted, link: *session_link.Link, worker: *session_worker.Worker, store: *board_store.Store) ?*shell_pick.Pick {
    const pick = allocator.create(shell_pick.Pick) catch return null;
    const rebuild = allocator.create(Rebuild) catch {
        allocator.destroy(pick);
        return null;
    };
    pick.* = .{ .allocator = allocator, .io = io, .store = store };
    rebuild.* = .{ .allocator = allocator, .io = io, .image = image, .apps = apps, .session = session, .shell = shell, .hosted = hosted, .link = link, .worker = worker, .pick = pick };
    pick.context = rebuild;
    pick.applyFn = applyRebuild;
    pick.chosen = store.restore();
    shell.pick = pick;
    const chosen = pick.chosen;
    const stem = if (chosen.board_len > 0) chosen.board() else board_profiles.default_board;
    shell.status.setMachine(stem, chosen.panel());
    return pick;
}

/// What a Board menu choice rebuilds, wired by local (main.zig).
pub const Rebuild = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// The ELF the session runs, kept across the rebuild.
    image: []const u8,
    /// The ThreadX apps staged onto the card at boot (RA8EMU-1142).
    apps: []const []const u8,
    session: *local_session.LocalSession,
    shell: *shell_loop.Shell,
    hosted: *?shell_hosted.Hosted,
    link: *session_link.Link,
    /// The worker the session rides, bound by local (main.zig).
    worker: *session_worker.Worker,
    /// The pick in force, for the status line's board and panel.
    pick: *shell_pick.Pick,

    /// Reopens the session with `profile`, the pick's composed text.
    pub fn apply(self: *Rebuild, profile: []const u8) !void {
        var replacement: local_session.LocalSession = undefined;
        try replacement.openRecordingApps(self.allocator, self.io, self.image, profile, if (self.pick.store) |s| s.dir else null, self.apps);
        // The session is reopened with the worker's thread stopped, and
        // answers again once everything points at the new one.
        self.worker.stop();
        self.session.setup.flushHistory() catch |err| {
            replacement.deinit();
            self.link.close();
            self.worker.rebind();
            self.link.openNative(&self.worker.native);
            if (self.shell.worker != null) try self.worker.start();
            return err;
        };
        self.link.close();
        if (self.hosted.*) |*held| held.listener.releaseSession();
        self.session.deinit();
        self.session.* = replacement;
        // The session rides the worker's native mailbox (RA8EMU-1196):
        // rebind rebuilt the Native in place, so the link reopens onto it.
        self.worker.rebind();
        self.link.openNative(&self.worker.native);
        if (self.shell.breaks) |breaks| breaks.reset();
        if (self.hosted.*) |*held| {
            held.rebind(&self.session.setup.context);
            held.announce(self.image, self.session.setup.owner.session());
        }
        const chosen = self.pick.chosen;
        const stem = if (chosen.board_len > 0) chosen.board() else board_profiles.default_board;
        self.shell.status.setMachine(stem, chosen.panel());
        // A headless, scripted or frame-counted run answers inline; only a
        // windowed one runs the worker's thread (shell.worker, set by
        // serveShell, tells the modes apart).
        if (self.shell.worker != null) try self.worker.start();
    }
};

pub fn applyRebuild(context: *anyopaque, profile: []const u8) anyerror!void {
    const self: *Rebuild = @ptrCast(@alignCast(context));
    return self.apply(profile);
}
