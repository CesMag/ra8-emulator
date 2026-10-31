//! The local session ra8_gui serves, started on the first image. The session
//! needs an image to come up, so a shell started with none runs without one:
//! the panes are empty and Run has nothing to run. The first image opened
//! from the picker, a drop or the recents starts it here, and every image
//! after that loads on the session the usual way (open.zig).
const std = @import("std");
const platform = @import("../platform.zig");
const session_link = @import("../session_link.zig");
const local_session = @import("../local_session.zig");
const session_worker = @import("../session_worker.zig");
const wall_clock = @import("../wall_clock.zig");
const shell_loop = @import("loop.zig");
const shell_hosted = @import("hosted.zig");
const shell_rebuild = @import("rebuild.zig");
const shell_camera = @import("camera/camera.zig");
const board_store = @import("board_store.zig");
const first_image = @import("first_image.zig");

pub const Boot = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    window: platform.Platform,
    /// The ThreadX apps staged onto the card at boot (RA8EMU-1142).
    apps: []const []const u8,
    /// The session answers on a thread of its own (main.zig's `apart`).
    apart: bool,
    clock: wall_clock.Clock,
    rx: []u8,
    tx: []u8,
    store: *board_store.Store,
    shell: *shell_loop.Shell = undefined,
    session: local_session.LocalSession = undefined,
    worker: session_worker.Worker = undefined,
    link: session_link.Link = undefined,
    hosted: ?shell_hosted.Hosted = null,
    /// The image the session came up on; null until one is opened.
    image: ?first_image.Image = null,

    /// Brings the session up on `image` and serves it to the shell. The
    /// drive loop loads the image once the session greets.
    pub fn start(self: *Boot, image: first_image.Image) !void {
        try self.session.openRecordingApps(self.allocator, self.io, image.path, null, self.store.dir, self.apps);
        errdefer self.session.deinit();
        // The local session rides the worker's native mailbox (RA8EMU-1196)
        // in both modes: the thread serves it only when someone is using the
        // window, and the shell's own thread drains it between frames
        // otherwise.
        self.worker.bind(self.io, self.allocator, &self.session, self.clock);
        self.link.openNative(&self.worker.native);
        const shell = self.shell;
        shell_hosted.bindHosted(&self.hosted, self.allocator, self.io, self.env, self.window, image.path, &self.session, &self.link, shell);
        shell.pick = shell_rebuild.launch(self.allocator, self.io, image.path, self.apps, &self.session, shell, &self.hosted, &self.link, &self.worker, self.store);
        if (shell.camera) |camera| camera.preview_provider = .{ .context = &self.session, .previewFn = cameraPreview };
        if (shell.files) |files| files.keep(image.path);
        self.image = image;
        // A headless, scripted or frame-counted run answers inline; a
        // windowed run answers on the worker's thread (serveShell starts it).
        if (self.apart) try self.worker.serveShell(shell) else shell.server = self.worker.inlineServer();
    }

    /// The shell's hook for an image opened while no session is up.
    pub fn hook(self: *Boot) shell_loop.Boot {
        return .{ .context = self, .startFn = startPicked };
    }

    /// Closes the link and ends the session, when one was started.
    pub fn deinit(self: *Boot) void {
        if (self.image == null) return;
        self.link.close();
        if (self.apart) self.worker.deinit();
        if (self.hosted) |*held| held.deinit();
        self.session.deinit();
    }
};

/// The event's path lasts only until the next poll, so the session gets a
/// copy. What cannot be read or started shows on the status strip.
fn startPicked(context: *anyopaque, path: []const u8) void {
    const self: *Boot = @ptrCast(@alignCast(context));
    if (self.image != null) return;
    const image = first_image.copy(self.allocator, self.io, path) orelse {
        self.shell.status.refused = .unread;
        return;
    };
    self.start(image) catch |err| {
        std.debug.print("ra8_gui: cannot start a session on {s}: {s}\n", .{ path, @errorName(err) });
        self.shell.status.refused = .load;
    };
}

fn cameraPreview(ctx: *anyopaque) ?shell_camera.PreviewFrame {
    const session: *local_session.LocalSession = @ptrCast(@alignCast(ctx));
    const prev = session.cameraPreview() orelse return null;
    return .{ .width = prev.width, .height = prev.height, .pixels = prev.pixels };
}
