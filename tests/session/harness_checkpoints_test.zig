//! Covers src/session/harness/checkpoints.zig: arming binds the
//! controller to the session's boundary with the harness's save stream
//! and the application's host side, and disarm releases the recorder.
const std = @import("std");
const ra8 = @import("ra8");

const checkpoints_mod = ra8.session.harness.checkpoints;
const scheduler = ra8.chip.core.scheduler;

/// Stand-in host side: the arming never fires the hook here, so the
/// functions only need to exist.
const Stub = struct {
    fn append(_: *anyopaque, _: []const u8) anyerror!void {}
    fn flush(_: *anyopaque) anyerror!void {}
    fn truncate(_: *anyopaque, _: u64) anyerror!void {}
    fn put(_: *anyopaque, _: ra8.session.history_recorder.Objects.Kind, _: []const u8, _: []const u8) anyerror!void {}
    fn sync(_: *anyopaque) anyerror!void {}
    fn tick(_: *anyopaque, _: u32) anyerror!void {}
    fn free(_: *anyopaque) anyerror!u64 {
        return 1_000;
    }
};

test "arming binds the controller to the session's boundary" {
    const gpa = std.testing.allocator;
    var context: u8 = 0;
    var session: ra8.session.zig.session.ZigSession = .{ .core = undefined, .machine = undefined, .budget = 1 };
    session.boundary = .{ .context = &context, .tickFn = Stub.tick };
    var store: ra8.chip.core.cpu.memory.store.Store = undefined;
    store.observer = null;
    var files: ra8.session.board.state.Files = undefined;
    files.store = &store;
    var saved: scheduler.State = .{};

    const armed = try checkpoints_mod.arm(
        gpa,
        &session,
        &files,
        &saved,
        .{ .context = &context, .append = Stub.append, .flush = Stub.flush, .truncate = Stub.truncate },
        .{ .context = &context, .put = Stub.put, .sync = Stub.sync },
        .{ .context = &context, .free = Stub.free, .cap = 100, .floor = 10 },
        600,
        64,
    );
    defer checkpoints_mod.disarm(gpa, armed);

    try std.testing.expect(session.checkpoints == &armed.checkpoints);
    try std.testing.expect(session.boundary.?.checkpointFn != null);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&armed.checkpoints)), session.boundary.?.checkpoint_context);
    try std.testing.expect(armed.recorder.objects != null);
    try std.testing.expectEqual(@as(u64, 100), armed.recorder.disk.?.cap);
    try std.testing.expectEqual(@as(u64, 10), armed.recorder.disk.?.floor);
    try std.testing.expectEqual(@as(u64, 600), armed.checkpoints.object_cap);
    try std.testing.expectEqual(@as(u32, 64), armed.checkpoints.every);
    // Every armed checkpoint pins the panel's picture.
    try std.testing.expect(armed.checkpoints.picture != null);
}

test "arming refusal restores previous store observer" {
    const gpa = std.testing.allocator;
    var context: u8 = 0;
    var session: ra8.session.zig.session.ZigSession = .{ .core = undefined, .machine = undefined, .budget = 1 };
    session.boundary = .{ .context = &context, .tickFn = Stub.tick };
    session.other = .{ .core = undefined, .machine = undefined };

    var dummy_observer: ra8.chip.core.cpu.memory.observer.Observer = undefined;
    var store: ra8.chip.core.cpu.memory.store.Store = undefined;
    store.observer = &dummy_observer;
    var files: ra8.session.board.state.Files = undefined;
    files.store = &store;
    var saved: scheduler.State = .{};

    const res = checkpoints_mod.arm(
        gpa,
        &session,
        &files,
        &saved,
        .{ .context = &context, .append = Stub.append, .flush = Stub.flush, .truncate = Stub.truncate },
        .{ .context = &context, .put = Stub.put, .sync = Stub.sync },
        .{ .context = &context, .free = Stub.free, .cap = 100, .floor = 10 },
        600,
        64,
    );
    try std.testing.expectError(error.SecondCore, res);
    try std.testing.expectEqual(&dummy_observer, store.observer);
}

test "disarm frees pending touched record" {
    const gpa = std.testing.allocator;
    var context: u8 = 0;
    var session: ra8.session.zig.session.ZigSession = .{ .core = undefined, .machine = undefined, .budget = 1 };
    session.boundary = .{ .context = &context, .tickFn = Stub.tick };
    var store: ra8.chip.core.cpu.memory.store.Store = undefined;
    store.observer = null;
    var files: ra8.session.board.state.Files = undefined;
    files.store = &store;
    var saved: scheduler.State = .{};

    const armed = try checkpoints_mod.arm(
        gpa,
        &session,
        &files,
        &saved,
        .{ .context = &context, .append = Stub.append, .flush = Stub.flush, .truncate = Stub.truncate },
        .{ .context = &context, .put = Stub.put, .sync = Stub.sync },
        .{ .context = &context, .free = Stub.free, .cap = 100, .floor = 10 },
        600,
        64,
    );

    const touched_mod = ra8.session.history_touched_pages;
    armed.checkpoints.touched_record = try touched_mod.Touched.fromDirty(gpa, 0, &armed.dirty);

    checkpoints_mod.disarm(gpa, armed);
}

test "saveMachine failure during writeTo frees touched record and keeps manifest intact" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = "tests/fixtures/display/ra8_ui.elf" });
    defer opened.deinit();

    var context: u8 = 0;
    var saved: scheduler.State = .{};

    const armed = try checkpoints_mod.arm(
        std.testing.allocator,
        &opened.session().live,
        &opened.state.files,
        &saved,
        .{ .context = &context, .append = Stub.append, .flush = Stub.flush, .truncate = Stub.truncate },
        .{ .context = &context, .put = Stub.put, .sync = Stub.sync },
        .{ .context = &context, .free = Stub.free, .cap = 100, .floor = 10 },
        600,
        64,
    );
    defer checkpoints_mod.disarm(std.testing.allocator, armed);

    const FailWriter = struct {
        fn drain(_: *std.Io.Writer, _: []const []const u8, _: usize) std.Io.Writer.Error!usize {
            return error.WriteFailed;
        }
    };
    const failing_vtable: std.Io.Writer.VTable = .{ .drain = FailWriter.drain };
    var failing_writer: std.Io.Writer = .{ .vtable = &failing_vtable, .buffer = &[_]u8{} };

    const res = armed.checkpoints.saveFn(armed, &failing_writer);
    try std.testing.expectError(error.WriteFailed, res);

    try std.testing.expect(armed.prev_manifest == null);
    try std.testing.expect(armed.checkpoints.touched_record == null);
}
