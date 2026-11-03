//! Tests for src/session/new_history.zig: a different image starts a new
//! history instead of being refused or forking.
const std = @import("std");
const ra8 = @import("ra8");

const session_api = ra8.session.api;
const branch_mod = ra8.session.history_branch;
const fork_router_mod = ra8.session.history_fork_router;
const root_mod = ra8.session.history_root;
const recorder_mod = ra8.session.history_recorder;
const Sink = @import("history/commit_sink.zig").Sink;
const new_history = ra8.session.new_history;

const root_image = "ROOT-IMAGE-ELF0";
const other_image = "ANOTHER-PROGRAM";

const Rig = struct {
    gpa: std.mem.Allocator,
    session: session_api.Session,
    graph: branch_mod.BranchGraph,
    router: fork_router_mod.ForkRouter,
    grid: ra8.chip.core.scheduler.State,
    root: root_mod.Root,
    loaded: ?[]const u8 = null,
    started: ?[]const u8 = null,
    fail_load: bool = false,
    sink_writes: usize = 0,

    fn create(gpa: std.mem.Allocator) !*Rig {
        const rig = try gpa.create(Rig);
        rig.* = .{
            .gpa = gpa,
            .session = undefined,
            .graph = try branch_mod.BranchGraph.init(gpa),
            .router = undefined,
            .grid = .{ .at = .{ .branch = 0, .r = 4, .phase = .cpu0, .o = 0, .gap = .retired } },
            .root = .{ .snapshot_version = 1, .elf0 = .{ .identity = root_mod.identity(root_image), .bytes = root_image } },
        };
        rig.router = fork_router_mod.ForkRouter.init(gpa, &rig.graph);
        rig.session = .{
            .live = .{ .core = undefined, .machine = undefined, .index = 0, .boundary = null, .budget = 1000 },
            .grid = &rig.grid,
        };
        rig.session.attachForkRouter(&rig.router);
        rig.session.attachRoot(&rig.root);
        rig.session.loader = .{ .context = rig, .loadFn = load };
        return rig;
    }

    fn destroy(rig: *Rig) void {
        rig.router.deinit();
        rig.graph.deinit();
        rig.gpa.destroy(rig);
    }

    fn load(context: *anyopaque, _: session_api.Core, image: []const u8) anyerror!void {
        const rig: *Rig = @ptrCast(@alignCast(context));
        if (rig.fail_load) return error.LoadRefused;
        rig.loaded = image;
    }

    fn write(context: *anyopaque, _: []const u8) anyerror!void {
        const rig: *Rig = @ptrCast(@alignCast(context));
        rig.sink_writes += 1;
    }

    fn start(context: *anyopaque, _: session_api.Core, image: []const u8) anyerror!void {
        const rig: *Rig = @ptrCast(@alignCast(context));
        rig.started = image;
    }
};

test "a different image loads live on a fresh base line and asks the application for a new history" {
    const rig = try Rig.create(std.testing.allocator);
    defer rig.destroy();
    rig.session.attachNewHistory(.{ .context = rig, .startFn = Rig.start });
    _ = try rig.graph.addBranch(0, .{ .branch = 0, .r = 2 }, .writes, 0);
    rig.router.switchActiveLine(1);
    rig.router.first_fork_confirmed = true;

    try std.testing.expect(new_history.differs(&rig.session, .cpu0, other_image));
    try rig.session.load(.cpu0, other_image);

    try std.testing.expectEqualStrings(other_image, rig.loaded.?);
    try std.testing.expectEqualStrings(other_image, rig.started.?);
    try std.testing.expect(rig.graph.get(1) == null);
    try std.testing.expect(rig.graph.get(0) != null);
    try std.testing.expectEqual(@as(u32, 0), rig.router.active_line);
    try std.testing.expect(!rig.router.first_fork_confirmed);
    try std.testing.expect(rig.router.pending_fork == null);
    try std.testing.expect(rig.session.root == null);
    // The new program is now the one the session compares against.
    try std.testing.expect(!new_history.differs(&rig.session, .cpu0, other_image));
    try std.testing.expect(new_history.differs(&rig.session, .cpu0, root_image));
}

test "the history's own image keeps its lines and goes through the router" {
    const rig = try Rig.create(std.testing.allocator);
    defer rig.destroy();
    _ = try rig.graph.addBranch(0, .{ .branch = 0, .r = 2 }, .writes, 0);

    try std.testing.expect(!new_history.differs(&rig.session, .cpu0, root_image));
    try rig.session.load(.cpu0, root_image);

    try std.testing.expectEqualStrings(root_image, rig.loaded.?);
    try std.testing.expect(rig.graph.get(1) != null);
    try std.testing.expect(rig.session.root != null);
}

test "without a new-history hook a recording session stops recording rather than mixing programs" {
    const rig = try Rig.create(std.testing.allocator);
    defer rig.destroy();
    var sink: Sink = .{};
    defer sink.bytes.deinit(std.testing.allocator);
    var recorder = try recorder_mod.Recorder.init(std.testing.allocator, sink.storage(), .{});
    defer recorder.deinit();
    rig.session.persistent_recorder = &recorder;

    try rig.session.load(.cpu0, other_image);

    try std.testing.expectEqualStrings(other_image, rig.loaded.?);
    try std.testing.expect(rig.session.persistent_recorder == null);
}

test "a session with no history never treats an image as different" {
    var session: session_api.Session = .{
        .live = .{ .core = undefined, .machine = undefined, .index = 0, .boundary = null, .budget = 1000 },
    };
    try std.testing.expect(!new_history.differs(&session, .cpu0, other_image));
}

test "image replacement flushes old events first and preserves the image on flush failure" {
    const rig = try Rig.create(std.testing.allocator);
    defer rig.destroy();
    var sink: Sink = .{ .fail_flush = true };
    defer sink.bytes.deinit(std.testing.allocator);
    var recorder = try recorder_mod.Recorder.init(std.testing.allocator, sink.storage(), .{});
    defer recorder.deinit();
    rig.session.persistent_recorder = &recorder;
    try recorder.recordIntervention(.{ .position = rig.grid.at, .seq = 0 }, .{ .what = .tap, .body = "old event" });

    try std.testing.expectError(error.FlushFailed, rig.session.load(.cpu0, other_image));
    try std.testing.expect(rig.loaded == null);
    try std.testing.expect(rig.session.root != null);
    try std.testing.expect(rig.session.persistent_recorder == &recorder);
    try std.testing.expect(recorder.pendingBytes() > 0);
    try std.testing.expectEqual(@as(usize, 0), sink.bytes.items.len);

    try rig.session.load(.cpu0, other_image);
    try std.testing.expectEqualStrings(other_image, rig.loaded.?);
    try std.testing.expectEqual(@as(usize, 0), recorder.pendingBytes());
    try std.testing.expect(sink.bytes.items.len > 0);
    try std.testing.expectEqual(@as(usize, 2), sink.flushes);
    try std.testing.expect(recorder.stopped);
}

test "a load that fails leaves the old image's lines and identity as they were" {
    const rig = try Rig.create(std.testing.allocator);
    defer rig.destroy();
    rig.session.attachNewHistory(.{ .context = rig, .startFn = Rig.start });
    _ = try rig.graph.addBranch(0, .{ .branch = 0, .r = 2 }, .writes, 0);
    rig.router.switchActiveLine(1);
    rig.fail_load = true;

    try std.testing.expectError(error.LoadRefused, rig.session.load(.cpu0, other_image));

    try std.testing.expect(rig.graph.get(1) != null);
    try std.testing.expectEqual(@as(u32, 1), rig.router.active_line);
    try std.testing.expect(rig.session.root != null);
    try std.testing.expect(rig.started == null);
    try std.testing.expect(!new_history.differs(&rig.session, .cpu0, root_image));
}

test "a session that stops recording leaves the old history's branches.bin alone" {
    const rig = try Rig.create(std.testing.allocator);
    defer rig.destroy();
    var sink: Sink = .{};
    defer sink.bytes.deinit(std.testing.allocator);
    var recorder = try recorder_mod.Recorder.init(std.testing.allocator, sink.storage(), .{});
    defer recorder.deinit();
    rig.session.persistent_recorder = &recorder;
    rig.session.attachGraphSink(.{ .context = rig, .writeFn = Rig.write });

    try rig.session.load(.cpu0, other_image);

    try std.testing.expect(recorder.stopped);
    try std.testing.expect(rig.session.graph_sink == null);
    // The fresh graph is the new program's; no later change reaches the file.
    try ra8.session.history_lifecycle.persistGraph(&rig.session);
    try std.testing.expectEqual(@as(usize, 0), rig.sink_writes);
}
