//! Tests for src/interfaces/rpc/history_bind.zig (RA8EMU-1196): the
//! application-side bridge serves the recorder's log storage and object
//! space over a host history session, and close deletes the session.
const std = @import("std");
const ra8 = @import("ra8");
const history = ra8.host.history;

const bind_mod = ra8.rpc.history_bind;
const NativeProbe = @import("object_stage_fixture.zig").NativeProbe;

test "successful probe cannot publish a replacement temporary file" {
    try replacedTemp(.replace);
}

test "aborting probe preserves a replacement temporary file on both platforms" {
    try replacedTemp(.replace_error);
}

fn replacedTemp(mode: @FieldType(NativeProbe, "mode")) !void {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const bind = try bind_mod.Bind.open(gpa, std.testing.io, root, .{});
    defer _ = bind.close() catch {};
    var dir = try history.paths.area(&bind.session, .objects);
    defer dir.close(std.testing.io);
    {
        var probe: NativeProbe = .{ .session = &bind.session, .mode = mode };
        bind.session.move_probe = probe.hook();
        defer bind.session.move_probe = null;
        try std.testing.expectError(error.IdentityConflict, bind.objects.put(bind.objects.context, .data, "target", "complete bytes"));
        try std.testing.expectError(error.FileNotFound, dir.statFile(std.testing.io, "target", .{}));
        const bytes = try ra8.rpc.object_read.read(history.storage.Store.from(&bind.session), gpa, probe.from[0..probe.len]);
        defer gpa.free(bytes);
        try std.testing.expectEqualStrings("foreign bytes", bytes);
        try std.testing.expect(bind.pending.names.contains("target"));
    }
}

test "published object failure leaves complete readable bytes and retry preserves first file" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const bind = try bind_mod.Bind.open(gpa, std.testing.io, root, .{});
    defer _ = bind.close() catch {};
    var probe: NativeProbe = .{ .session = &bind.session, .mode = .published };
    bind.session.move_probe = probe.hook();
    try std.testing.expectError(error.InjectedPublished, bind.objects.put(bind.objects.context, .data, "target", "complete bytes"));
    bind.session.move_probe = null;
    const store = history.storage.Store.from(&bind.session);
    const bytes = try ra8.rpc.object_read.read(store, gpa, "target");
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("complete bytes", bytes);
    var dir = try history.paths.area(&bind.session, .objects);
    defer dir.close(std.testing.io);
    const before = try dir.statFile(std.testing.io, "target", .{});
    try bind.objects.put(bind.objects.context, .data, "target", "complete bytes");
    try std.testing.expectEqual(before.inode, (try dir.statFile(std.testing.io, "target", .{})).inode);
}

test "Linux persistent rename intent and both linked fallback error prefixes survive retry" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const bind = try bind_mod.Bind.open(gpa, std.testing.io, root, .{});
    defer _ = bind.close() catch {};
    const modes = [_]@FieldType(NativeProbe, "mode"){ .intent, .fallback_link, .fallback_unlink };
    const faults = [_]anyerror{ error.InjectedIntent, error.InjectedLinked, error.InjectedUnlinked };
    for (modes, faults, 0..) |mode, fault, index| {
        var probe: NativeProbe = .{ .session = &bind.session, .mode = mode };
        bind.session.move_probe = probe.hook();
        try std.testing.expectError(fault, bind.objects.put(bind.objects.context, .data, "target", "complete bytes"));
        bind.session.move_probe = null;
        const disk = bind.disk.?;
        try disk.relief.?(disk.context);
        var pending = (try history.rename.pending(std.testing.io, bind.session.dir)) orelse return error.LostRenameIntent;
        defer pending.deinit();
        var dir = try history.paths.area(&bind.session, .objects);
        defer dir.close(std.testing.io);
        if (index < 2) {
            const from = try ra8.rpc.object_read.read(history.storage.Store.from(&bind.session), gpa, probe.from[0..probe.len]);
            defer gpa.free(from);
            try std.testing.expectEqualStrings("complete bytes", from);
        }
        try bind.objects.put(bind.objects.context, .data, "target", "complete bytes");
        try std.testing.expect((try history.rename.pending(std.testing.io, bind.session.dir)) == null);
        if (index != 0) try std.testing.expectError(error.FileNotFound, dir.statFile(std.testing.io, probe.from[0..probe.len], .{}));
        try disk.relief.?(disk.context);
        try std.testing.expectError(error.FileNotFound, dir.statFile(std.testing.io, probe.from[0..probe.len], .{}));
        const bytes = try ra8.rpc.object_read.read(history.storage.Store.from(&bind.session), gpa, "target");
        defer gpa.free(bytes);
        try std.testing.expectEqualStrings("complete bytes", bytes);
        try dir.deleteFile(std.testing.io, "target");
    }
}

test "Linux live relief protects exact recovery inputs across abandonment then reclaims settled garbage" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    try @import("object_relief_fixture.zig").abandoned();
}

test "live relief refuses incomplete and unreadable notes before deleting any orphan" {
    try @import("object_relief_fixture.zig").invalid();
}

test "Linux live relief refuses wrong identity notes before deleting any orphan" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    try @import("object_relief_fixture.zig").conflicts();
}

test "existing partial canonical object refuses reuse and preserves original bytes" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const bind = try bind_mod.Bind.open(gpa, std.testing.io, root, .{});
    defer _ = bind.close() catch {};
    const store = history.storage.Store.from(&bind.session);
    const file = try store.vtable.open(store.context, .objects, "partial", .create);
    defer file.vtable.close(file.context);
    try file.vtable.write(file.context, 0, "pa");
    try file.vtable.sync(file.context);
    try std.testing.expectError(error.ObjectConflict, bind.objects.put(bind.objects.context, .data, "partial", "partial object complete bytes"));
    try std.testing.expectEqual(@as(u64, 2), try file.vtable.length(file.context));
    var kept: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try file.vtable.read(file.context, 0, &kept));
    try std.testing.expectEqualStrings("pa", &kept);
    try std.testing.expect(bind.pending.names.contains("partial"));
}

test "red control: new loose object put writes and syncs a temporary file before atomic rename" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const bind = try bind_mod.Bind.open(gpa, std.testing.io, root, .{});
    defer _ = bind.close() catch {};
    var dir = try history.paths.area(&bind.session, .objects);
    defer dir.close(std.testing.io);
    const Probe = struct {
        saw_temp_before_final: bool = false,
        expect_final_absent: bool = true,
        abort_once: bool = false,
        replace_temp: bool = false,
        replaced_name: [64]u8 = undefined,
        replaced_len: usize = 0,
        fn reach(ctx: *anyopaque, phase: history.move.probe.Phase, source: std.Io.Dir, from: []const u8, _: std.Io.Dir, to: []const u8) anyerror!void {
            if (phase != .native_before) return;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, from, to)) return error.DirectCanonicalWrite;
            const stat = try source.statFile(std.testing.io, from, .{ .follow_symlinks = false });
            try std.testing.expectEqual(@as(u64, "complete object payload".len), stat.size);
            if (self.expect_final_absent) {
                try std.testing.expectError(error.FileNotFound, source.statFile(std.testing.io, to, .{ .follow_symlinks = false }));
            }
            self.saw_temp_before_final = true;
            if (self.replace_temp) {
                @memcpy(self.replaced_name[0..from.len], from);
                self.replaced_len = from.len;
                try source.writeFile(std.testing.io, .{ .sub_path = "impostor-seed", .data = "impostor" });
                try source.deleteFile(std.testing.io, from);
                try history.move.preserve(std.testing.io, source, "impostor-seed", source, from);
                return error.InjectedBeforeRename;
            }
            if (self.abort_once) {
                self.abort_once = false;
                return error.InjectedBeforeRename;
            }
        }
    };
    var probe: Probe = .{ .abort_once = true };
    bind.session.move_probe = .{ .context = &probe, .reached = Probe.reach };
    defer bind.session.move_probe = null;
    try std.testing.expectError(error.InjectedBeforeRename, bind.objects.put(bind.objects.context, .data, "atomic-target", "complete object payload"));
    try std.testing.expect(probe.saw_temp_before_final);
    try std.testing.expect(bind.pending.names.contains("atomic-target"));
    try std.testing.expectError(error.FileNotFound, dir.statFile(std.testing.io, "atomic-target", .{ .follow_symlinks = false }));

    try bind.objects.put(bind.objects.context, .data, "atomic-target", "complete object payload");
    const store = history.storage.Store.from(&bind.session);
    const immediate = try ra8.rpc.object_read.read(store, gpa, "atomic-target");
    defer gpa.free(immediate);
    try std.testing.expectEqualStrings("complete object payload", immediate);

    if (@import("builtin").os.tag == .linux) {
        probe.expect_final_absent = false;
        const winner = try history.move.file.state(dir, "atomic-target");
        try bind.objects.put(bind.objects.context, .data, "atomic-target", "complete object payload");
        try std.testing.expect(winner.same(try history.move.file.state(dir, "atomic-target")));

        probe.expect_final_absent = true;
        probe.replace_temp = true;
        try std.testing.expectError(error.IdentityConflict, bind.objects.put(bind.objects.context, .data, "replaced-temp-target", "complete object payload"));
        const imp = try ra8.rpc.object_read.read(store, gpa, probe.replaced_name[0..probe.replaced_len]);
        defer gpa.free(imp);
        try std.testing.expectEqualStrings("impostor", imp);
    }
}

test "an explicit cap sizes the bind's budget and scales its pieces" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const cap = history.budget.bytes.floor;
    const plain = try bind_mod.Bind.open(gpa, std.testing.io, root, .{});
    const plain_floor = plain.disk.?.floor;
    _ = plain.close() catch {};
    const bind = try bind_mod.Bind.open(gpa, std.testing.io, root, .{ .cap = cap });
    defer _ = bind.close() catch {};
    try std.testing.expectEqual(cap, bind.disk.?.cap);
    try std.testing.expectEqual(cap * 60 / 100, bind.checkpoint_cap);
    try std.testing.expectEqual(plain_floor, bind.disk.?.floor);
}

test "a cap below the minimum share refuses the open" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    try std.testing.expectError(error.BudgetTooSmall, bind_mod.Bind.open(gpa, std.testing.io, root, .{ .cap = 1024 }));
}

test "the bind appends the log, puts objects and deletes its session on close" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const bind = try bind_mod.Bind.open(gpa, std.testing.io, root, .{});
    try bind.storage.append(bind.storage.context, "hello");
    try bind.storage.append(bind.storage.context, "world");
    try bind.storage.flush(bind.storage.context);
    try std.testing.expectEqual(@as(u64, 10), try bind.logLength());
    try bind.storage.truncate(bind.storage.context, 5);
    try bind.storage.append(bind.storage.context, "!");
    try std.testing.expectEqual(@as(u64, 6), try bind.logLength());
    try bind.objects.put(bind.objects.context, .data, "0123456789abcdef", "object bytes");
    try bind.objects.put(bind.objects.context, .data, "0123456789abcdef", "object bytes");
    const store = history.storage.Store.from(&bind.session);
    const log = try store.vtable.open(store.context, .log, "events-0", .read);
    var log_bytes: [6]u8 = undefined;
    const seen = try log.vtable.read(log.context, 0, &log_bytes);
    log.vtable.close(log.context);
    try std.testing.expectEqual(@as(usize, 6), seen);
    try std.testing.expectEqualStrings("hello!", &log_bytes);
    const object = try store.vtable.open(store.context, .objects, "0123456789abcdef", .read);
    var object_bytes: [12]u8 = undefined;
    const held = try object.vtable.read(object.context, 0, &object_bytes);
    object.vtable.close(object.context);
    try std.testing.expectEqual(@as(usize, 12), held);
    try std.testing.expectEqualStrings("object bytes", &object_bytes);
    try std.testing.expect(bind.disk != null);
    try std.testing.expect(bind.disk.?.cap > 0);
    try std.testing.expect(bind.disk.?.floor > 0);
    try std.testing.expect(try bind.disk.?.free(bind.disk.?.context) > 0);
    try std.testing.expectEqual(history.session.Outcome.deleted, try bind.close());
}

test "switchSegment creates events-<branch>-<seg> preserving parent segment byte-for-byte" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const bind = try bind_mod.Bind.open(gpa, std.testing.io, root, .{});
    defer _ = bind.close() catch {};

    const parent_bytes = "parent-future-preserved";
    try bind.storage.append(bind.storage.context, parent_bytes);
    try bind.storage.flush(bind.storage.context);
    try std.testing.expectEqual(@as(u64, parent_bytes.len), try bind.logLength());

    const sw = bind.storage.switchSegment orelse return error.NoSwitchSegment;
    try std.testing.expectEqual(@as(u64, 0), try sw(bind.storage.context, 1, 0));

    const child_bytes = "child-branch-1-content";
    try bind.storage.append(bind.storage.context, child_bytes);
    try bind.storage.flush(bind.storage.context);
    try std.testing.expectEqual(@as(u64, child_bytes.len), try bind.logLength());

    const store = history.storage.Store.from(&bind.session);
    const parent_file = try store.vtable.open(store.context, .log, "events-0", .read);
    defer parent_file.vtable.close(parent_file.context);
    var read_parent: [64]u8 = undefined;
    const parent_len = try parent_file.vtable.read(parent_file.context, 0, &read_parent);
    try std.testing.expectEqual(parent_bytes.len, parent_len);
    try std.testing.expectEqualStrings(parent_bytes, read_parent[0..parent_len]);

    const child_file = try store.vtable.open(store.context, .log, "events-1-0", .read);
    defer child_file.vtable.close(child_file.context);
    var read_child: [64]u8 = undefined;
    const child_len = try child_file.vtable.read(child_file.context, 0, &read_child);
    try std.testing.expectEqual(child_bytes.len, child_len);
    try std.testing.expectEqualStrings(child_bytes, read_child[0..child_len]);
}

const Pictures = struct {
    fn save(_: *anyopaque, writer: *std.Io.Writer) anyerror!void {
        try writer.writeAll("machine");
    }
    fn scan(_: *anyopaque, allocator: std.mem.Allocator, at: ra8.session.history_checkpoint_picture.Position) anyerror!?ra8.session.history_checkpoint_picture.Decoded {
        return .{ .position = at, .virtual_ns = 1, .width = 4, .height = 2, .pixels = try allocator.dupe(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }) };
    }
};

test "relief through the bind's referrer drops orphans and keeps checkpoint pictures" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const bind = try bind_mod.Bind.open(gpa, std.testing.io, root, .{});
    defer _ = bind.close() catch {};

    var rec = try ra8.session.history_recorder.Recorder.init(gpa, bind.storage, .{});
    defer rec.deinit();
    rec.observe(0);
    rec.objects = bind.objects;
    var saved: ra8.chip.core.scheduler.State = .{ .at = .{ .r = 2 } };
    var context: u8 = 0;
    var cp: ra8.session.history_checkpoint.Checkpoint = .{
        .context = &context,
        .saveFn = Pictures.save,
        .recorder = &rec,
        .saved = &saved,
        .every = 1,
        .picture = .{ .context = &context, .lastScanFn = Pictures.scan },
    };
    try cp.fire(2);
    try bind.objects.put(bind.objects.context, .data, "ffffffffffffffffffffffffffffffff", "stray");

    try std.testing.expect(bind_mod.prune_referrer.pictures != null);
    const store = history.storage.Store.from(&bind.session);
    const report = try history.prune.relief(store, gpa, bind_mod.prune_referrer);
    try std.testing.expectEqual(@as(usize, 1), report.orphans);
    try std.testing.expectEqual(@as(usize, 1), report.pictures_kept);
    try std.testing.expect(report.intact());
}
