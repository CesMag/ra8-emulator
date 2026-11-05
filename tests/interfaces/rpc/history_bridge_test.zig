//! Tests for src/interfaces/rpc/history_bridge.zig: the bridge between the
//! served session and host history storage. Its facts report the session's
//! reverse window so the transport's planners can pick it as a base, and it
//! tears down cleanly on allocation failures.
const std = @import("std");
const ra8 = @import("ra8");
const rig = @import("../../session/history/window_rig.zig");

const setup = ra8.rpc.served_setup;
const bridge_mod = ra8.rpc.history_bridge;
const budget = ra8.host.history.budget;
const ram_mod = ra8.rpc.history_ram;
const touched_pages = ra8.session.history_touched_pages;
const seek_engine = ra8.session.history_seek_engine;
const dirty_pages = ra8.session.history_dirty_pages;

const gpa = std.testing.allocator;

test "the bridge's facts carry the window's span, cursor, line and slot count" {
    var served: setup.Served = undefined;
    try served.open(gpa, std.testing.io, rig.image_path, rig.profile, .{ .ram_budget = 256 * budget.bytes.mib });
    defer served.deinit();
    try rig.countFixture(&served.owner);
    const session = served.owner.session();
    try session.setRunBudget(.cpu0, 1);
    _ = try session.run(.cpu0, .cont);
    try rig.runCount(&served.owner, 40);

    const facts = try bridge_mod.Bridge.facts(&served.bridge.?);
    const window = facts.window orelse return error.TestExpectedWindow;
    const w = session.window.?;
    try std.testing.expectEqual(@as(u64, 41), window.slots);
    try std.testing.expect(std.meta.eql(window.start, w.start().?));
    try std.testing.expect(std.meta.eql(window.end, w.end().?));
    try std.testing.expect(std.meta.eql(window.at, session.grid.?.at));
    try std.testing.expectEqual(w.line, window.line);

    // A window that holds no run is not offered to the planners.
    w.drop();
    const bare = try bridge_mod.Bridge.facts(&served.bridge.?);
    try std.testing.expect(bare.window == null);
}

test "loadTouchedRecords attaches decoded touched records from ram history" {
    var session: ra8.session.api.Session = undefined;
    const ram = try ram_mod.RamHistory.open(gpa, 8192);
    defer ram.deinit();

    var dirty = try dirty_pages.DirtyPages.init(gpa);
    defer dirty.deinit();
    dirty.markDirty(.cpu0_mram, 1);
    var t = try touched_pages.Touched.fromDirty(gpa, 0, &dirty);
    defer t.deinit();

    var staging: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 4096);
    defer staging.deinit();
    try t.encode(&staging.writer);
    const encoded_bytes = staging.written();

    const obj_id: [16]u8 = @splat(0x34);
    const t_name = touched_pages.objectName(obj_id);
    try ram.object_space.put(ram.object_space.context, .touched, &t_name, encoded_bytes);

    var bridge: bridge_mod.Bridge = .{
        .gpa = gpa,
        .session = &session,
        .ram = ram,
    };
    defer bridge.deinit();

    var checkpoints = [_]seek_engine.Checkpoint{
        .{
            .id = 1,
            .position = .{},
            .object = obj_id,
        },
    };

    try bridge.loadTouchedRecords(&checkpoints);
    try std.testing.expect(checkpoints[0].touched != null);
    try std.testing.expect(checkpoints[0].touched.?.isTouched(.{ .space = .cpu0_mram, .page_index = 1 }));
    try std.testing.expect(!checkpoints[0].touched.?.isTouched(.{ .space = .cpu0_mram, .page_index = 2 }));
}

test "loadTouchedRecords cleans up on allocation failure" {
    var session: ra8.session.api.Session = undefined;
    const ram = try ram_mod.RamHistory.open(gpa, 8192);
    defer ram.deinit();

    var dirty = try dirty_pages.DirtyPages.init(gpa);
    defer dirty.deinit();
    dirty.markDirty(.cpu0_mram, 1);
    var t = try touched_pages.Touched.fromDirty(gpa, 0, &dirty);
    defer t.deinit();

    var staging: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    defer staging.deinit();
    try t.encode(&staging.writer);
    const encoded_bytes = staging.written();

    const obj_id: [16]u8 = @splat(0x56);
    const t_name = touched_pages.objectName(obj_id);
    try ram.object_space.put(ram.object_space.context, .touched, &t_name, encoded_bytes);

    for ([_]usize{ 12, 13 }) |fail_idx| {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_idx });
        var bridge: bridge_mod.Bridge = .{
            .gpa = failing.allocator(),
            .session = &session,
            .ram = ram,
        };
        defer bridge.deinit();

        var checkpoints = [_]seek_engine.Checkpoint{
            .{
                .id = 1,
                .position = .{},
                .object = obj_id,
            },
        };

        const res = bridge.loadTouchedRecords(&checkpoints);
        try std.testing.expectError(error.OutOfMemory, res);
    }
}
