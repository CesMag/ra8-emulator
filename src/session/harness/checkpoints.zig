//! The harness's checkpoint arming (RA8EMU-1196): the closed-round
//! controller bound to the run's own save stream, fed by the
//! application's host storage and object space.
const std = @import("std");
const history_checkpoint = @import("../history/checkpoint.zig");
const history_recorder = @import("../history/recorder.zig");
const session_state = @import("../board/state.zig");
const scheduler = @import("ra8_chip").core.scheduler;
const zig_session = @import("../zig/session.zig");
const picture = @import("picture.zig");
const checkpoint_engine = @import("../history/checkpoint_engine.zig");
const dirty_pages = @import("../history/dirty_pages.zig");
const manifest_mod = @import("../history/manifest.zig");
const observer_mod = @import("ra8_chip").core.cpu.memory.observer;

/// The armed pair in one heap-stable box: the recorder owns the staging,
/// the controller owns the policy, and the boundary's hook points here,
/// so arming survives `wire`'s return.
pub const Armed = struct {
    allocator: std.mem.Allocator,
    recorder: history_recorder.Recorder,
    checkpoints: history_checkpoint.Checkpoint,
    files: *session_state.Files,
    engine: checkpoint_engine.CheckpointEngine,
    dirty: dirty_pages.DirtyPages,
    prev_manifest: ?manifest_mod.Manifest = null,
    prev_observer: ?*const observer_mod.Observer = null,
    dirty_observer: observer_mod.Observer = undefined,
    sink_ctx: SinkContext = .{},
    has_store: bool = false,
};

/// Arms the closed-round checkpoints on a session whose application bound
/// both a log storage and an object space. A second core refuses through
/// the session's own arming (RA8EMU-768).
pub fn arm(
    allocator: std.mem.Allocator,
    session: *zig_session.ZigSession,
    files: *session_state.Files,
    saved: *const scheduler.State,
    storage: history_recorder.Storage,
    objects: history_recorder.Objects,
    disk: ?history_recorder.Budget,
    checkpoint_cap: u64,
    every: u32,
) !*Armed {
    const armed = try allocator.create(Armed);
    errdefer allocator.destroy(armed);
    armed.allocator = allocator;
    armed.recorder = try history_recorder.Recorder.init(allocator, storage, .{});
    errdefer armed.recorder.deinit();
    armed.recorder.objects = objects;
    armed.recorder.disk = disk;
    armed.files = files;
    armed.engine = checkpoint_engine.CheckpointEngine.init(allocator);
    errdefer armed.engine.deinit();
    armed.dirty = try dirty_pages.DirtyPages.init(allocator);
    errdefer armed.dirty.deinit();
    armed.prev_manifest = null;
    armed.sink_ctx = .{ .objects = objects };
    armed.has_store = true;
    armed.prev_observer = files.store.observer;
    armed.dirty.prev_observer = armed.prev_observer;
    armed.dirty_observer = armed.dirty.storeObserver();
    files.store.observer = &armed.dirty_observer;
    errdefer files.store.observer = armed.prev_observer;
    armed.checkpoints = .{
        .context = armed,
        .saveFn = saveMachine,
        .recorder = &armed.recorder,
        .saved = saved,
        .every = every,
        .object_cap = checkpoint_cap,
        // Every checkpoint pins the panel's picture beside the machine.
        .picture = picture.source(files),
    };
    try session.armCheckpoints(&armed.checkpoints);
    return armed;
}

/// Releases an armed pair: the recorder's staging goes and the box goes;
/// the application's storage and object space outlive both.
pub fn disarm(allocator: std.mem.Allocator, armed: *Armed) void {
    if (armed.has_store) {
        armed.files.store.observer = armed.prev_observer;
    }
    if (armed.prev_manifest) |*m| m.deinit(allocator);
    if (armed.checkpoints.touched_record) |*t| t.deinit();
    if (armed.checkpoints.manifest_record) |m| allocator.free(m);
    armed.engine.deinit();
    armed.dirty.deinit();
    armed.recorder.deinit();
    allocator.destroy(armed);
}

/// The whole machine's save stream: the bytes a state file carries. A
/// checkpoint's object is the run file a restore reads back.
fn saveMachine(context: *anyopaque, writer: *std.Io.Writer) anyerror!void {
    const armed: *Armed = @ptrCast(@alignCast(context));
    var sink: ?checkpoint_engine.ObjectSink = null;
    if (armed.recorder.objects) |objs| {
        armed.sink_ctx = .{ .objects = objs };
        sink = .{ .context = &armed.sink_ctx, .putFn = SinkContext.putFn };
    }
    const cap_res = try armed.engine.captureFromFiles(
        armed.files,
        &armed.dirty,
        if (armed.prev_manifest) |*m| m else null,
        armed.checkpoints.saved.at,
        armed.checkpoints.next_id,
        null,
        sink,
        null,
    );
    var cap_manifest = cap_res.manifest;
    errdefer cap_manifest.deinit(armed.allocator);
    var touched = armed.engine.takeTouched();
    errdefer if (touched) |*t| t.deinit();
    try armed.files.writeTo(writer);
    if (armed.prev_manifest) |*m| m.deinit(armed.allocator);
    var encoded: std.Io.Writer.Allocating = try .initCapacity(armed.allocator, 4096);
    errdefer encoded.deinit();
    try manifest_mod.encode(&cap_manifest, &encoded.writer);
    if (armed.checkpoints.manifest_record) |old| armed.allocator.free(old);
    armed.checkpoints.manifest_record = try encoded.toOwnedSlice();
    armed.prev_manifest = cap_manifest;
    armed.checkpoints.touched_record = touched;
}

const SinkContext = struct {
    objects: ?history_recorder.Objects = null,

    fn putFn(context: *anyopaque, id: checkpoint_engine.ObjectId, bytes: []const u8) anyerror!void {
        const self: *SinkContext = @ptrCast(@alignCast(context));
        if (self.objects) |objs| {
            if (objs.putPacked) |packed_put| return packed_put(objs.context, id.bytes, bytes);
            var name: [32]u8 = undefined;
            for (id.bytes, 0..) |byte, i| {
                _ = std.fmt.bufPrint(name[i * 2 ..][0..2], "{x:0>2}", .{byte}) catch unreachable;
            }
            try objs.put(objs.context, .data, &name, bytes);
        }
    }
};

/// Arms the checkpoints on the session's boundary and makes their recorder
/// the session's persistent recorder and the rewind history's too, so
/// interventions, landings, forks' Branch records and segment switches
/// reach the one log the checkpoints write.
pub fn armSession(
    allocator: std.mem.Allocator,
    session: *session_api.Session,
    history: *session_history.History,
    files: *session_state.Files,
    saved: *const scheduler.State,
    storage: history_recorder.Storage,
    objects: history_recorder.Objects,
    disk: ?history_recorder.Budget,
    checkpoint_cap: u64,
    every: u32,
) !*Armed {
    const armed = try arm(allocator, &session.live, files, saved, storage, objects, disk, checkpoint_cap, every);
    session.attachPersistentRecorder(&armed.recorder);
    history.attachRecorder(&armed.recorder);
    if (session.console_hook == null) session.attachConsole(.{ .context = files.board, .feedFn = feedBoardConsole });
    files.board.console_input.hook = .{ .context = session, .feedFn = routeConsoleStdin };
    return armed;
}

/// Disarms what armSession armed, detaching the recorder first.
pub fn disarmSession(allocator: std.mem.Allocator, session: *session_api.Session, history: *session_history.History, armed: *Armed) void {
    if (session.persistent_recorder == &armed.recorder) session.persistent_recorder = null;
    if (history.recorder == &armed.recorder) history.recorder = null;
    disarm(allocator, armed);
}

fn feedBoardConsole(context: *anyopaque, bytes: []const u8) anyerror!void {
    const board: *@import("ra8_board").board.Board = @ptrCast(@alignCast(context));
    board.serial.feed(@import("ra8_chip").periph.sci.console_channel, bytes);
}

fn routeConsoleStdin(context: *anyopaque, bytes: []const u8) void {
    const session: *session_api.Session = @ptrCast(@alignCast(context));
    session.consoleInput(.cpu0, bytes) catch {};
}

const session_api = @import("../api.zig");
const session_history = @import("../history.zig");
