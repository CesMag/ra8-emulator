//! Hands the devices pane's plug and unplug requests from the window to
//! the engine (RA8EMU-703), the way source_swap.zig hands camera picks
//! over: the board's lines are only ever written on the engine's thread.
//!
//! In a shown run the session's plug hook is `hook()`, so Session.plug and
//! unplug queue the change and publish their event on the window's thread
//! at once; the engine applies the queue at its next park, oldest first,
//! through the board's own hook. A change the board refuses there comes
//! back through `takeRefused`, for the panel to put its row back.
const std = @import("std");
const session_api = @import("ra8_session").session_api;

pub const Endpoint = session_api.Endpoint;
pub const Error = error{QueueFull};

/// One change: put `name` on `at`, or take what is there off when null.
pub const Request = struct {
    at: Endpoint,
    name: ?[]const u8,
};

pub const limits = struct {
    /// Requests one park can carry; a click per frame never comes close.
    pub const pending: usize = 8;
};

pub const PlugPost = struct {
    /// Window and engine threads lock through it; neither cancels.
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    queue: [limits.pending]Request = undefined,
    count: usize = 0,
    refused: [limits.pending]Request = undefined,
    refused_count: usize = 0,

    /// Window side: the session's plug hook, which queues the change.
    pub fn hook(self: *PlugPost) session_api.PlugHook {
        return .{ .context = self, .plugFn = post };
    }

    fn post(context: *anyopaque, at: Endpoint, name: ?[]const u8) anyerror!void {
        const self: *PlugPost = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.count == limits.pending) return Error.QueueFull;
        self.queue[self.count] = .{ .at = at, .name = name };
        self.count += 1;
    }

    /// Engine side, at a park: apply every queued change through `board`,
    /// oldest first, keeping the ones it refused. Returns how many landed.
    pub fn apply(self: *PlugPost, board: session_api.PlugHook) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var landed: usize = 0;
        for (self.queue[0..self.count]) |request| {
            if (board.plugFn(board.context, request.at, request.name)) |_| {
                landed += 1;
            } else |_| self.keepRefused(request);
        }
        self.count = 0;
        return landed;
    }

    /// A full refusal list drops the oldest, so the newest are reported.
    fn keepRefused(self: *PlugPost, request: Request) void {
        if (self.refused_count == limits.pending) {
            std.mem.copyForwards(Request, self.refused[0 .. limits.pending - 1], self.refused[1..]);
            self.refused_count -= 1;
        }
        self.refused[self.refused_count] = request;
        self.refused_count += 1;
    }

    /// Window side: the changes the board refused since the last call,
    /// oldest first, copied into `out` (at most `limits.pending`).
    pub fn takeRefused(self: *PlugPost, out: *[limits.pending]Request) []Request {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const count = self.refused_count;
        @memcpy(out[0..count], self.refused[0..count]);
        self.refused_count = 0;
        return out[0..count];
    }
};
