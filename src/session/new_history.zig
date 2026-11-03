//! A different image starts a new history (time-travel design section 11).
//!
//! The old history's lines describe another program's run, so loading a
//! different image never forks from them and is never refused: the session
//! drops its lines back to a fresh base line, asks the application to open
//! a new history if it bound a hook for that, and loads the image live. A
//! session that records into a persistent history but has no such hook
//! stops recording rather than mixing two programs into one history.
const std = @import("std");
const api = @import("api.zig");
const apply = @import("apply.zig");
const line = @import("line.zig");
const replay_feeder = @import("history/replay_feeder.zig");
const branch_mod = @import("history/branch.zig");
const history_root = @import("history/root.zig");
const async_traffic = @import("history/async_traffic.zig");

const Session = api.Session;
const Core = api.Core;

/// Whether `image` is a different program from the one this session's
/// history recorded for `core`. A session with no history has nothing to
/// differ from.
pub fn differs(self: *const Session, core: Core, image: []const u8) bool {
    const id = history_root.identity(image);
    if (self.root) |root| {
        const expected = switch (core) {
            .cpu0 => root.elf0.identity,
            .cpu1 => if (root.elf1) |elf1| elf1.identity else return true,
        };
        return !std.mem.eql(u8, &expected, &id);
    }
    if (self.fork_router == null) return false;
    const seen = self.image_identity[@backingInt(core)] orelse return false;
    return !std.mem.eql(u8, &seen, &id);
}

/// Starts a new history for `image` on `core` and loads it live. The
/// fresh graph is made and the image loaded before anything else changes,
/// so running out of memory or a load that fails leaves the old image's
/// lines, identity and history as they were.
pub fn start(self: *Session, core: Core, image: []const u8) anyerror!void {
    var fresh: ?branch_mod.BranchGraph = null;
    if (self.fork_router) |router| if (router.graph) |graph| {
        fresh = try branch_mod.BranchGraph.init(graph.allocator);
    };
    errdefer if (fresh) |*graph| graph.deinit();
    if (self.persistent_recorder) |rec| try rec.force();
    try apply.applyAction(self, .{ .load = .{ .core = core, .image = image } });
    resetLines(self, &fresh);
    self.root = null;
    self.image_identity = .{ null, null };
    self.image_identity[@backingInt(core)] = history_root.identity(image);
    const hook = self.new_history orelse return stopRecording(self);
    hook.startFn(hook.context, core, image) catch |err| {
        stopRecording(self);
        return err;
    };
    if (self.root == null) stopRecording(self);
}

/// Ends recording into the old history without touching it: the recorder
/// stages, checkpoints and commits nothing more (its checkpoint policy
/// shares it), and branches.bin is never rewritten for the new program.
fn stopRecording(self: *Session) void {
    if (self.persistent_recorder) |rec| rec.stopped = true;
    self.persistent_recorder = null;
    if (self.history) |h| h.recorder = null;
    self.graph_sink = null;
}

/// Back to a single base line: no branches, no pending fork, nothing
/// queued or replayed. `fresh` is the graph swapped in; it is spent here.
fn resetLines(self: *Session, fresh: *?branch_mod.BranchGraph) void {
    _ = async_traffic.clearOnFork(self);
    replay_feeder.release(self);
    const router = self.fork_router orelse return;
    router.cancel();
    router.first_fork_confirmed = false;
    router.seq = 0;
    if (router.graph) |graph| {
        graph.deinit();
        graph.* = fresh.*.?;
        fresh.* = null;
    }
    router.switchActiveLine(branch_mod.root_branch_id);
    line.stampLine(self);
}
