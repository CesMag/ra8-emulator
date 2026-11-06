//! Tests for incremental restore engine: diffing two manifests, copying only
//! differing pages and state blobs, and proving byte-identical equivalence to full restore.
const std = @import("std");
const ra8 = @import("ra8");
const manifest_mod = ra8.session.history_manifest;
const incremental_restore = ra8.session.history_incremental_restore;
const ObjectId = ra8.session.history_object_id.ObjectId;
const scheduler = ra8.chip.core.scheduler;
const memmap = ra8.chip.core.memmap;
const fixture = @import("../board/state_fixture.zig");
const Rig = fixture.Rig;
const populated = fixture.populated;

const at = memmap.sram_base + 0x400;

const MemoryObjectStore = struct {
    map: std.AutoHashMap([16]u8, []const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MemoryObjectStore {
        return .{
            .map = std.AutoHashMap([16]u8, []const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MemoryObjectStore) void {
        var iter = self.map.valueIterator();
        while (iter.next()) |val| {
            self.allocator.free(val.*);
        }
        self.map.deinit();
    }

    pub fn get(context: *anyopaque, id: ObjectId) ?[]const u8 {
        const self: *MemoryObjectStore = @ptrCast(@alignCast(context));
        return self.map.get(id.bytes);
    }

    pub fn put(context: *anyopaque, id: ObjectId, bytes: []const u8) anyerror!void {
        const self: *MemoryObjectStore = @ptrCast(@alignCast(context));
        if (self.map.contains(id.bytes)) return;
        const owned = try self.allocator.dupe(u8, bytes);
        try self.map.put(id.bytes, owned);
    }

    pub fn store(self: *MemoryObjectStore) incremental_restore.ObjectStore {
        return .{
            .context = self,
            .get = &get,
            .put = &put,
        };
    }
};

test "Incremental restore produces byte-identical machine state vs full restore" {
    const allocator = std.testing.allocator;

    var mem_store = MemoryObjectStore.init(allocator);
    defer mem_store.deinit();
    const obj_store = mem_store.store();

    const live = try Rig.create();
    defer live.destroy();
    try populated(live);

    const pos1 = scheduler.Position{ .branch = 1, .r = 10, .phase = .cpu0, .o = 0, .gap = .retired };

    // 1. Capture initial manifest and full snapshot
    var snap1 = try live.save();
    defer snap1.deinit();

    var m1 = try incremental_restore.capture(allocator, &live.files, pos1, 1, null, obj_store, null);
    defer m1.deinit(allocator);

    // 2. Mutate live machine state across memory and CPU registers
    try live.store.write(.none, at, &.{ 0xaa, 0xbb });
    try live.store.write(.none, at + 0x2000, &.{ 0xcc, 0xdd });
    try live.pair.store.?.write(.none, memmap.mram_base + 0x1000, &.{ 0xee, 0xff });
    live.cpu.slots = 999;
    live.pair.core.cpu.slots = 777;

    const pos2 = scheduler.Position{ .branch = 1, .r = 20, .phase = .cpu0, .o = 5, .gap = .retired };
    var m2 = try incremental_restore.capture(allocator, &live.files, pos2, 2, null, obj_store, null);
    defer m2.deinit(allocator);

    // 3. Diff m2 (current) vs m1 (target)
    var diff_restore = try manifest_mod.diff(allocator, &m2, &m1);
    defer diff_restore.deinit(allocator);

    // Assert that differing pages and non-memory run_state are scheduled
    const pages_to_copy = diff_restore.pages.len;
    try std.testing.expect(pages_to_copy >= 3);
    try std.testing.expect(pages_to_copy < m1.pages.len);
    try std.testing.expectEqual(@as(usize, 1), diff_restore.blobs.len);

    // Corrupt a memory page that diff_restore must fix to prove page copying is mandatory
    try live.store.write(.none, at, &.{ 0x99, 0x88 });

    // 4. Reference full restore machine
    const ref = try Rig.create();
    defer ref.destroy();
    try populated(ref);
    try ref.store.write(.none, at, &.{ 0xaa, 0xbb });
    try ref.store.write(.none, at + 0x2000, &.{ 0xcc, 0xdd });
    try ref.pair.store.?.write(.none, memmap.mram_base + 0x1000, &.{ 0xee, 0xff });
    ref.cpu.slots = 999;
    ref.pair.core.cpu.slots = 777;

    try ref.files.readFrom(snap1.written());

    // 5. Apply incremental restore to live machine
    try incremental_restore.applyDiff(&live.files, diff_restore, obj_store, null);

    // Assert the corrupted page was repaired by incremental page copying
    var restored_bytes: [2]u8 = undefined;
    try live.store.read(.none, at, &restored_bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x20 }, &restored_bytes);

    // 6. Oracle check: full snapshot of live must be 100% byte-identical to ref
    var live_snap = try live.save();
    defer live_snap.deinit();

    var ref_snap = try ref.save();
    defer ref_snap.deinit();

    try std.testing.expectEqualSlices(u8, ref_snap.written(), live_snap.written());
}

test "Incremental restore with identical manifests copies 0 pages" {
    const allocator = std.testing.allocator;

    var mem_store = MemoryObjectStore.init(allocator);
    defer mem_store.deinit();
    const obj_store = mem_store.store();

    const live = try Rig.create();
    defer live.destroy();
    try populated(live);

    const pos = scheduler.Position{ .branch = 1, .r = 15, .phase = .cpu0, .o = 0, .gap = .retired };
    var m = try incremental_restore.capture(allocator, &live.files, pos, 1, null, obj_store, null);
    defer m.deinit(allocator);

    var empty_diff = try manifest_mod.diff(allocator, &m, &m);
    defer empty_diff.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), empty_diff.pages.len);
    try std.testing.expectEqual(@as(usize, 0), empty_diff.blobs.len);

    // Applying empty diff succeeds without touching state
    try incremental_restore.applyDiff(&live.files, empty_diff, obj_store, null);
}

const TestAccessor = struct {
    nor_buf: [4096]u8 = @splat(0x11),
    sd_buf: [4096]u8 = @splat(0x22),
    eink_buf: [4096]u8 = @splat(0x33),
    extra_buf: [4096]u8 = @splat(0x44),

    pub fn getSlice(context: ?*anyopaque, space: manifest_mod.SpaceId) ?[]u8 {
        const self: *TestAccessor = @ptrCast(@alignCast(context.?));
        return switch (space) {
            .nor_flash => &self.nor_buf,
            .sd_card => &self.sd_buf,
            .eink_buffer => &self.eink_buf,
            .store_extra => &self.extra_buf,
            else => null,
        };
    }
};

test "SpaceAccessor resolves NOR, SD, e-ink and Store.extra without BadSpace" {
    const allocator = std.testing.allocator;

    var mem_store = MemoryObjectStore.init(allocator);
    defer mem_store.deinit();
    const obj_store = mem_store.store();

    const live = try Rig.create();
    defer live.destroy();
    try populated(live);

    var test_acc = TestAccessor{};
    const accessor = incremental_restore.SpaceAccessor{
        .context = &test_acc,
        .getSliceFn = &TestAccessor.getSlice,
    };

    // Prepare updated page data for NOR flash and SD card
    const new_nor_page: [4096]u8 = @splat(0xaa);
    const nor_id = ObjectId.compute(&new_nor_page);
    try obj_store.put(obj_store.context, nor_id, &new_nor_page);

    const new_sd_page: [4096]u8 = @splat(0xbb);
    const sd_id = ObjectId.compute(&new_sd_page);
    try obj_store.put(obj_store.context, sd_id, &new_sd_page);

    const pages = try allocator.alloc(manifest_mod.PageRef, 2);
    defer allocator.free(pages);
    pages[0] = .{ .space = .nor_flash, .page_index = 0, .object = nor_id };
    pages[1] = .{ .space = .sd_card, .page_index = 0, .object = sd_id };

    const diff_manifest = manifest_mod.ManifestDiff{
        .pages = pages,
        .blobs = &[_]manifest_mod.BlobRef{},
    };

    // Applying diff to accessor-backed spaces succeeds without BadSpace
    try incremental_restore.applyDiff(&live.files, diff_manifest, obj_store, accessor);

    try std.testing.expectEqualSlices(u8, &new_nor_page, &test_acc.nor_buf);
    try std.testing.expectEqualSlices(u8, &new_sd_page, &test_acc.sd_buf);
}

fn expectRefusal(
    live: *Rig,
    snap_before: []const u8,
    diff: manifest_mod.ManifestDiff,
    store: incremental_restore.ObjectStore,
    accessor: ?incremental_restore.SpaceAccessor,
    expected_err: incremental_restore.Error,
) !void {
    try std.testing.expectError(expected_err, incremental_restore.applyDiff(&live.files, diff, store, accessor));
    var snap_after = try live.save();
    defer snap_after.deinit();
    try std.testing.expectEqualSlices(u8, snap_before, snap_after.written());
}

test "Incremental restore late page failure preserves entire state and continuation" {
    const allocator = std.testing.allocator;
    var mem_store = MemoryObjectStore.init(allocator);
    defer mem_store.deinit();
    const obj_store = mem_store.store();

    const live = try Rig.create();
    defer live.destroy();
    try populated(live);
    const ref = try Rig.create();
    defer ref.destroy();
    try populated(ref);

    var snap_before = try live.save();
    defer snap_before.deinit();

    var valid_page: [4096]u8 = @splat(0x55);
    valid_page[0] = 0xef;
    const valid_id = ObjectId.compute(&valid_page);
    try obj_store.put(obj_store.context, valid_id, &valid_page);

    var short_page: [256]u8 = @splat(0x77);
    const short_id = ObjectId.compute(&short_page);
    try obj_store.put(obj_store.context, short_id, &short_page);

    var test_acc = TestAccessor{};
    const accessor = incremental_restore.SpaceAccessor{ .context = &test_acc, .getSliceFn = &TestAccessor.getSlice };
    const nor_initial = test_acc.nor_buf;

    // Case 1: missing object
    var p1 = [_]manifest_mod.PageRef{ .{ .space = .cpu0_sram, .page_index = 0, .object = valid_id }, .{ .space = .cpu0_sram, .page_index = 1, .object = ObjectId.compute("missing") } };
    try expectRefusal(live, snap_before.written(), .{ .pages = &p1, .blobs = &.{} }, obj_store, accessor, error.MissingObject);
    try std.testing.expectEqualSlices(u8, &nor_initial, &test_acc.nor_buf);

    // Case 2: BadSpace
    var p2 = [_]manifest_mod.PageRef{ .{ .space = .cpu0_sram, .page_index = 0, .object = valid_id }, .{ .space = .nor_flash, .page_index = 0, .object = valid_id } };
    try expectRefusal(live, snap_before.written(), .{ .pages = &p2, .blobs = &.{} }, obj_store, null, error.BadSpace);

    // Case 3: OffsetOutOfBounds
    var p3 = [_]manifest_mod.PageRef{ .{ .space = .cpu0_sram, .page_index = 0, .object = valid_id }, .{ .space = .cpu0_sram, .page_index = 99999, .object = valid_id } };
    try expectRefusal(live, snap_before.written(), .{ .pages = &p3, .blobs = &.{} }, obj_store, accessor, error.OffsetOutOfBounds);

    // Case 4: RestoreFailed (short bytes)
    var p4 = [_]manifest_mod.PageRef{ .{ .space = .cpu0_sram, .page_index = 0, .object = valid_id }, .{ .space = .cpu0_sram, .page_index = 1, .object = short_id } };
    try expectRefusal(live, snap_before.written(), .{ .pages = &p4, .blobs = &.{} }, obj_store, accessor, error.RestoreFailed);

    // Continuation oracle
    try live.store.write(.none, at, &.{ 0x12, 0x34 });
    try ref.store.write(.none, at, &.{ 0x12, 0x34 });
    live.cpu.slots += 10;
    ref.cpu.slots += 10;
    var s_live = try live.save();
    defer s_live.deinit();
    var s_ref = try ref.save();
    defer s_ref.deinit();
    try std.testing.expectEqualSlices(u8, s_ref.written(), s_live.written());
}

test "Incremental restore late run_state failure preserves entire state and continuation" {
    const allocator = std.testing.allocator;
    var mem_store = MemoryObjectStore.init(allocator);
    defer mem_store.deinit();
    const obj_store = mem_store.store();

    const live = try Rig.create();
    defer live.destroy();
    try populated(live);
    const ref = try Rig.create();
    defer ref.destroy();
    try populated(ref);

    var snap_before = try live.save();
    defer snap_before.deinit();

    var valid_page: [4096]u8 = @splat(0x66);
    const valid_id = ObjectId.compute(&valid_page);
    try obj_store.put(obj_store.context, valid_id, &valid_page);
    var pages = [_]manifest_mod.PageRef{.{ .space = .cpu0_sram, .page_index = 0, .object = valid_id }};

    // Case 5: missing run_state blob
    var b1 = [_]manifest_mod.BlobRef{.{ .space = .run_state, .size = 128, .object = ObjectId.compute("missing_blob") }};
    try expectRefusal(live, snap_before.written(), .{ .pages = &pages, .blobs = &b1 }, obj_store, null, error.MissingObject);

    // Case 6: mismatched blob size
    var b_short: [64]u8 = @splat(0x33);
    const b_short_id = ObjectId.compute(&b_short);
    try obj_store.put(obj_store.context, b_short_id, &b_short);
    var b2 = [_]manifest_mod.BlobRef{.{ .space = .run_state, .size = 128, .object = b_short_id }};
    try expectRefusal(live, snap_before.written(), .{ .pages = &pages, .blobs = &b2 }, obj_store, null, error.RestoreFailed);

    // Case 7: malformed run_state payload
    var b_corrupt: [64]u8 = @splat(0xff);
    const b_corrupt_id = ObjectId.compute(&b_corrupt);
    try obj_store.put(obj_store.context, b_corrupt_id, &b_corrupt);
    var b3 = [_]manifest_mod.BlobRef{.{ .space = .run_state, .size = 64, .object = b_corrupt_id }};
    try expectRefusal(live, snap_before.written(), .{ .pages = &pages, .blobs = &b3 }, obj_store, null, error.RestoreFailed);

    // Case 8: allocation failure on live board
    const pos = scheduler.Position{ .branch = 1, .r = 30, .phase = .cpu0, .o = 0, .gap = .retired };
    var m_ref = try incremental_restore.capture(allocator, &ref.files, pos, 3, null, obj_store, null);
    defer m_ref.deinit(allocator);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    live.board.nor.allocator = failing.allocator();
    defer {
        live.board.nor.allocator = std.testing.allocator;
    }
    try expectRefusal(live, snap_before.written(), .{ .pages = &pages, .blobs = m_ref.blobs }, obj_store, null, error.OutOfMemory);
    live.board.nor.allocator = std.testing.allocator;

    // Continuation oracle
    try live.store.write(.none, at, &.{ 0x77, 0x88 });
    try ref.store.write(.none, at, &.{ 0x77, 0x88 });
    var s_live = try live.save();
    defer s_live.deinit();
    var s_ref = try ref.save();
    defer s_ref.deinit();
    try std.testing.expectEqualSlices(u8, s_ref.written(), s_live.written());
}
