//! Content-addressed checkpoint engine.
//!
//! Produces Merkle manifests capturing machine state. Clean pages reuse
//! previous manifest identities without rehashing or disk I/O; dirty pages
//! are hashed and deduplicated across spaces and time before being emitted
//! to an injected object sink.
const std = @import("std");
const manifest_mod = @import("manifest.zig");
pub const ObjectId = @import("object_id.zig").ObjectId;
const Position = @import("position.zig").Position;
const DirtyPages = @import("dirty_pages.zig").DirtyPages;
const page_size = @import("dirty_pages.zig").page_size;
const Touched = @import("touched_pages.zig").Touched;
const snap_state = @import("../root.zig").board.state;
const Files = snap_state.Files;
const inc_restore = @import("incremental_restore.zig");
const getSpaceSlice = inc_restore.getSpaceSlice;
const SpaceAccessor = inc_restore.SpaceAccessor;

pub const SpaceSpan = struct {
    space: manifest_mod.SpaceId,
    bytes: []const u8,
};

pub const BlobSpan = struct {
    space: manifest_mod.SpaceId,
    bytes: []const u8,
};

pub const ObjectSink = struct {
    context: *anyopaque,
    putFn: *const fn (context: *anyopaque, id: ObjectId, bytes: []const u8) anyerror!void,

    pub fn put(self: ObjectSink, id: ObjectId, bytes: []const u8) anyerror!void {
        return self.putFn(self.context, id, bytes);
    }
};

pub const CaptureStats = struct {
    pages_hashed: usize = 0,
    pages_reused: usize = 0,
    objects_stored: usize = 0,
};

pub const CaptureResult = struct {
    manifest: manifest_mod.Manifest,
    stats: CaptureStats,
};

const DirtyCoord = struct {
    space: manifest_mod.SpaceId,
    page_index: u32,
};

pub const CheckpointEngine = struct {
    allocator: std.mem.Allocator,
    seen_objects: std.AutoHashMap([16]u8, void),
    last_stats: CaptureStats = .{},
    /// The pages written between the previous capture and the last one,
    /// null after a first capture. The engine owns it; `takeTouched` hands
    /// it to whoever keeps it beside the manifest.
    last_touched: ?Touched = null,

    pub fn init(allocator: std.mem.Allocator) CheckpointEngine {
        return .{
            .allocator = allocator,
            .seen_objects = std.AutoHashMap([16]u8, void).init(allocator),
        };
    }

    pub fn deinit(self: *CheckpointEngine) void {
        self.dropTouched();
        self.seen_objects.deinit();
        self.* = undefined;
    }

    pub fn reset(self: *CheckpointEngine) void {
        self.seen_objects.clearRetainingCapacity();
        self.last_stats = .{};
        self.dropTouched();
    }

    fn dropTouched(self: *CheckpointEngine) void {
        if (self.last_touched) |*held| held.deinit();
        self.last_touched = null;
    }

    /// Transfers the last capture's touched-page record to the caller,
    /// who owns it and must deinit it.
    pub fn takeTouched(self: *CheckpointEngine) ?Touched {
        const held = self.last_touched;
        self.last_touched = null;
        return held;
    }

    pub fn registerManifest(self: *CheckpointEngine, manifest: *const manifest_mod.Manifest) !void {
        var last_page: ?ObjectId = null;
        for (manifest.pages) |page| {
            if (last_page) |prev| if (prev.eql(page.object)) continue;
            last_page = page.object;
            try self.seen_objects.put(page.object.bytes, {});
        }
        for (manifest.blobs) |blob| {
            try self.seen_objects.put(blob.object.bytes, {});
        }
    }

    fn storeObject(
        self: *CheckpointEngine,
        id: ObjectId,
        bytes: []const u8,
        sink: ?ObjectSink,
        stats: *CaptureStats,
    ) !void {
        const gop = try self.seen_objects.getOrPut(id.bytes);
        if (!gop.found_existing) {
            if (sink) |s| {
                try s.put(id, bytes);
            }
            stats.objects_stored += 1;
        }
    }

    fn resolvePage(
        self: *CheckpointEngine,
        dirty: *const DirtyPages,
        dirty_clears: *std.ArrayList(DirtyCoord),
        prev_manifest: ?*const manifest_mod.Manifest,
        prev_pages: []const manifest_mod.PageRef,
        prev_cursor: *usize,
        span: SpaceSpan,
        p_idx: usize,
        sink: ?ObjectSink,
        stats: *CaptureStats,
    ) !ObjectId {
        const is_dirty = if (prev_manifest != null)
            dirty.isDirty(span.space, @intCast(p_idx))
        else
            true;

        if (!is_dirty and prev_manifest != null) {
            if (prev_cursor.* < prev_pages.len) {
                const cur = prev_pages[prev_cursor.*];
                if (cur.space == span.space and cur.page_index == @as(u32, @intCast(p_idx))) {
                    prev_cursor.* += 1;
                    stats.pages_reused += 1;
                    return cur.object;
                }
            }
            if (findPage(prev_pages, span.space, @intCast(p_idx))) |obj| {
                stats.pages_reused += 1;
                return obj;
            }
        }

        if (prev_manifest != null) {
            try dirty_clears.append(self.allocator, .{ .space = span.space, .page_index = @intCast(p_idx) });
        }

        const start = p_idx * page_size;
        const end = @min(span.bytes.len, start + page_size);
        const page_data = span.bytes[start..end];
        const id = ObjectId.compute(page_data);
        try self.storeObject(id, page_data, sink, stats);
        stats.pages_hashed += 1;
        return id;
    }

    fn collectPages(
        self: *CheckpointEngine,
        dirty: *const DirtyPages,
        dirty_clears: *std.ArrayList(DirtyCoord),
        prev_manifest: ?*const manifest_mod.Manifest,
        spaces: []const SpaceSpan,
        sink: ?ObjectSink,
        stats: *CaptureStats,
    ) ![]manifest_mod.PageRef {
        var total_pages: usize = 0;
        for (spaces) |span| {
            total_pages += (span.bytes.len + page_size - 1) / page_size;
        }
        const page_refs = try self.allocator.alloc(manifest_mod.PageRef, total_pages);
        errdefer self.allocator.free(page_refs);

        const prev_pages = if (prev_manifest) |prev| prev.pages else &[_]manifest_mod.PageRef{};
        var prev_cursor: usize = 0;
        var out_idx: usize = 0;

        for (spaces) |span| {
            const count = (span.bytes.len + page_size - 1) / page_size;
            for (0..count) |p_idx| {
                const obj_id = try self.resolvePage(
                    dirty,
                    dirty_clears,
                    prev_manifest,
                    prev_pages,
                    &prev_cursor,
                    span,
                    p_idx,
                    sink,
                    stats,
                );
                page_refs[out_idx] = .{
                    .space = span.space,
                    .page_index = @intCast(p_idx),
                    .object = obj_id,
                };
                out_idx += 1;
            }
        }

        if (!std.sort.isSorted(manifest_mod.PageRef, page_refs, {}, pageLessThan)) {
            std.mem.sort(manifest_mod.PageRef, page_refs, {}, pageLessThan);
        }
        return page_refs;
    }

    fn collectBlobs(
        self: *CheckpointEngine,
        blobs: []const BlobSpan,
        sink: ?ObjectSink,
        stats: *CaptureStats,
    ) ![]manifest_mod.BlobRef {
        const blob_refs = try self.allocator.alloc(manifest_mod.BlobRef, blobs.len);
        errdefer self.allocator.free(blob_refs);

        for (blobs, 0..) |blob, i| {
            const id = ObjectId.compute(blob.bytes);
            try self.storeObject(id, blob.bytes, sink, stats);
            blob_refs[i] = .{
                .space = blob.space,
                .object = id,
                .size = @intCast(blob.bytes.len),
            };
        }

        std.mem.sort(manifest_mod.BlobRef, blob_refs, {}, blobLessThan);
        return blob_refs;
    }

    pub fn capture(
        self: *CheckpointEngine,
        dirty: *DirtyPages,
        prev_manifest: ?*const manifest_mod.Manifest,
        pos: Position,
        checkpoint_id: u32,
        picture: ?ObjectId,
        spaces: []const SpaceSpan,
        blobs: []const BlobSpan,
        sink: ?ObjectSink,
    ) !CaptureResult {
        if (prev_manifest) |prev| {
            try self.registerManifest(prev);
        }

        var stats: CaptureStats = .{};
        var dirty_clears: std.ArrayList(DirtyCoord) = .empty;
        defer dirty_clears.deinit(self.allocator);

        const pages = try self.collectPages(dirty, &dirty_clears, prev_manifest, spaces, sink, &stats);
        errdefer self.allocator.free(pages);

        const blob_refs = try self.collectBlobs(blobs, sink, &stats);
        errdefer self.allocator.free(blob_refs);

        const root = manifest_mod.computeMerkleRoot(pos, checkpoint_id, picture, pages, blob_refs);

        // The write record for the interval since the previous capture,
        // copied before the bits clear.
        var touched: ?Touched = if (prev_manifest) |prev|
            try Touched.fromDirty(self.allocator, prev.checkpoint_id, dirty)
        else
            null;
        errdefer if (touched) |*t| t.deinit();

        // Atomic dirty clearing: only upon full capture success
        if (prev_manifest == null) {
            dirty.clearAll();
        } else {
            for (dirty_clears.items) |coord| {
                dirty.clearDirty(coord.space, coord.page_index);
            }
        }

        self.last_stats = stats;
        self.dropTouched();
        self.last_touched = touched;
        touched = null;

        return .{
            .manifest = .{
                .position = pos,
                .checkpoint_id = checkpoint_id,
                .picture = picture,
                .pages = pages,
                .blobs = blob_refs,
                .root_hash = root,
            },
            .stats = stats,
        };
    }

    pub fn captureFromFiles(
        self: *CheckpointEngine,
        files: *Files,
        dirty: *DirtyPages,
        prev_manifest: ?*const manifest_mod.Manifest,
        pos: Position,
        checkpoint_id: u32,
        picture: ?ObjectId,
        sink: ?ObjectSink,
        accessor: ?SpaceAccessor,
    ) !CaptureResult {
        var spans: [12]SpaceSpan = undefined;
        var count: usize = 0;
        const tracked_spaces = [_]manifest_mod.SpaceId{
            .cpu0_mram,   .cpu0_dtcm, .cpu0_sram, .cpu0_sdram,
            .cpu0_ppb,    .cpu1_mram, .cpu1_dtcm, .cpu1_ppb,
            .store_extra, .nor_flash, .sd_card,   .eink_buffer,
        };
        for (tracked_spaces) |space| {
            if (getSpaceSlice(files, space, accessor)) |slice| {
                spans[count] = .{ .space = space, .bytes = slice };
                count += 1;
            }
        }
        var full_snap: std.Io.Writer.Allocating = try .initCapacity(self.allocator, 1024);
        defer full_snap.deinit();
        try files.writeParts(&full_snap.writer, .{ .memory = false });
        const blob_spans = [_]BlobSpan{.{
            .space = .run_state,
            .bytes = full_snap.written(),
        }};
        return self.capture(dirty, prev_manifest, pos, checkpoint_id, picture, spans[0..count], &blob_spans, sink);
    }
};

pub fn findPage(pages: []const manifest_mod.PageRef, space: manifest_mod.SpaceId, page_index: u32) ?ObjectId {
    var low: usize = 0;
    var high: usize = pages.len;
    const target_space = @backingInt(space);
    while (low < high) {
        const mid = low + (high - low) / 2;
        const mid_item = pages[mid];
        const item_space = @backingInt(mid_item.space);
        if (target_space < item_space) {
            high = mid;
        } else if (target_space > item_space) {
            low = mid + 1;
        } else if (page_index < mid_item.page_index) {
            high = mid;
        } else if (page_index > mid_item.page_index) {
            low = mid + 1;
        } else {
            return mid_item.object;
        }
    }
    return null;
}

fn pageLessThan(_: void, a: manifest_mod.PageRef, b: manifest_mod.PageRef) bool {
    const sa = @backingInt(a.space);
    const sb = @backingInt(b.space);
    if (sa != sb) return sa < sb;
    return a.page_index < b.page_index;
}

fn blobLessThan(_: void, a: manifest_mod.BlobRef, b: manifest_mod.BlobRef) bool {
    const sa = @backingInt(a.space);
    const sb = @backingInt(b.space);
    if (sa != sb) return sa < sb;
    return std.mem.order(u8, &a.object.bytes, &b.object.bytes) == .lt;
}
