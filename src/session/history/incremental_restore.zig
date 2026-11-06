//! Incremental restore engine: diffs two manifests, determines the exact list
//! of 4 KiB pages and state blobs to copy, and applies them to machine state.
//!
//! Applying the diff must yield a machine byte-identical to a full restore.
//! Clean pages are preserved without re-copying or re-hashing.
const std = @import("std");
const manifest_mod = @import("manifest.zig");
const ObjectId = @import("object_id.zig").ObjectId;
const Position = @import("position.zig").Position;
const snap_state = @import("../root.zig").board.state;
const Files = snap_state.Files;
const memmap = @import("ra8_chip").core.memmap;
const file = @import("ra8_snapshot").file;

pub const page_size: usize = 0x1000; // 4096 bytes

pub const Error = error{
    MissingObject,
    BadSpace,
    OffsetOutOfBounds,
    RestoreFailed,
    OutOfMemory,
};

pub const ObjectStore = struct {
    context: *anyopaque,
    get: *const fn (context: *anyopaque, id: ObjectId) ?[]const u8,
    put: *const fn (context: *anyopaque, id: ObjectId, bytes: []const u8) anyerror!void,
};

pub const SpaceAccessor = struct {
    context: ?*anyopaque = null,
    getSliceFn: ?*const fn (context: ?*anyopaque, space: manifest_mod.SpaceId) ?[]u8 = null,

    pub fn getSlice(self: SpaceAccessor, space: manifest_mod.SpaceId) ?[]u8 {
        if (self.getSliceFn) |func| return func(self.context, space);
        return null;
    }
};

/// Resolves the memory slice for an owned guest memory space in Files.
pub fn getSpaceSlice(files: *Files, space: manifest_mod.SpaceId, accessor: ?SpaceAccessor) ?[]u8 {
    if (accessor) |acc| {
        if (acc.getSlice(space)) |slice| return slice;
    }
    return switch (space) {
        .cpu0_mram => if (files.store.pages[0]) |p| p else null,
        .cpu0_dtcm => if (files.store.pages[1]) |p| p else null,
        .cpu0_sram => if (files.store.pages[2]) |p| p else null,
        .cpu0_ppb => if (files.store.pages[3]) |p| p else null,
        .cpu0_sdram => if (files.store.port) |port| port.sdram else null,
        .cpu1_mram => if (files.pair) |pair| if (pair.store) |s| s.pages[0] else null else null,
        .cpu1_dtcm => if (files.pair) |pair| if (pair.store) |s| s.pages[1] else null else null,
        .cpu1_ppb => if (files.pair) |pair| if (pair.store) |s| s.pages[3] else null else null,
        .store_extra => blk: {
            for (files.store.extra.windows) |w| {
                if (w) |win| break :blk win.bytes;
            }
            break :blk null;
        },
        else => null,
    };
}

/// Captures a complete Manifest from a machine's Files state, storing all page
/// and non-memory blobs into objects.
pub fn capture(
    allocator: std.mem.Allocator,
    files: *Files,
    pos: Position,
    checkpoint_id: u32,
    picture: ?ObjectId,
    objects: ObjectStore,
    accessor: ?SpaceAccessor,
) !manifest_mod.Manifest {
    var p_list: std.ArrayList(manifest_mod.PageRef) = .empty;
    defer p_list.deinit(allocator);

    const paged_spaces = [_]manifest_mod.SpaceId{
        .cpu0_mram,   .cpu0_dtcm, .cpu0_sram, .cpu0_sdram,
        .cpu0_ppb,    .cpu1_mram, .cpu1_dtcm, .cpu1_ppb,
        .store_extra, .nor_flash, .sd_card,   .eink_buffer,
    };

    for (paged_spaces) |space| {
        const slice = getSpaceSlice(files, space, accessor) orelse continue;
        const total_pages = slice.len / page_size;
        for (0..total_pages) |p_idx| {
            const page_data = slice[p_idx * page_size .. (p_idx + 1) * page_size];
            const obj_id = ObjectId.compute(page_data);
            try objects.put(objects.context, obj_id, page_data);
            try p_list.append(allocator, .{
                .space = space,
                .page_index = @intCast(p_idx),
                .object = obj_id,
            });
        }
    }

    var full_snap: std.Io.Writer.Allocating = try .initCapacity(allocator, 1024);
    defer full_snap.deinit();
    try files.writeParts(&full_snap.writer, .{ .memory = false });

    var b_list: std.ArrayList(manifest_mod.BlobRef) = .empty;
    defer b_list.deinit(allocator);

    const snap_data = full_snap.written();
    const snap_obj_id = ObjectId.compute(snap_data);
    try objects.put(objects.context, snap_obj_id, snap_data);
    try b_list.append(allocator, .{
        .space = .run_state,
        .size = @intCast(snap_data.len),
        .object = snap_obj_id,
    });

    const pages = try p_list.toOwnedSlice(allocator);
    const blobs = try b_list.toOwnedSlice(allocator);
    const root = manifest_mod.computeMerkleRoot(pos, checkpoint_id, picture, pages, blobs);

    return .{
        .position = pos,
        .checkpoint_id = checkpoint_id,
        .picture = picture,
        .pages = pages,
        .blobs = blobs,
        .root_hash = root,
    };
}

/// Applies an incremental restore diff to the machine. Only differing pages are
/// copied into memory, and non-paged state blobs are committed.
///
/// Fully transactional: all page and blob references are validated and run_state
/// is prepared before committing any live memory mutations. Any refusal leaves
/// the machine and accessor bytes completely untouched.
pub fn applyDiff(
    files: *Files,
    diff_manifest: manifest_mod.ManifestDiff,
    objects: ObjectStore,
    accessor: ?SpaceAccessor,
) Error!void {
    // 1. Validate all memory page references before modifying state
    for (diff_manifest.pages) |p_ref| {
        const space_slice = getSpaceSlice(files, p_ref.space, accessor) orelse return Error.BadSpace;
        const offset = @as(usize, p_ref.page_index) * page_size;
        if (offset + page_size > space_slice.len) return Error.OffsetOutOfBounds;

        const page_bytes = objects.get(objects.context, p_ref.object) orelse return Error.MissingObject;
        if (page_bytes.len != page_size) return Error.RestoreFailed;
    }

    // 2. Validate all blob references before modifying state
    var run_state_bytes: ?[]const u8 = null;
    for (diff_manifest.blobs) |b_ref| {
        if (b_ref.space == .run_state) {
            if (run_state_bytes != null) return Error.RestoreFailed;
            const snap_bytes = objects.get(objects.context, b_ref.object) orelse return Error.MissingObject;
            if (snap_bytes.len != b_ref.size) return Error.RestoreFailed;
            run_state_bytes = snap_bytes;
        } else {
            return Error.BadSpace;
        }
    }

    // 3. Stage and commit run_state blob first.
    // readParts performs internal staging and validation before committing non-memory state.
    // If readParts fails, files is untouched and no memory pages have been copied.
    if (run_state_bytes) |snap_bytes| {
        files.readParts(snap_bytes, .{ .memory = false }) catch |err| switch (err) {
            error.OutOfMemory => return Error.OutOfMemory,
            else => return Error.RestoreFailed,
        };
    }

    // 4. Commit differing 4 KiB memory pages.
    // All pages, offsets, and objects were pre-validated in step 1, so memory copying is safe.
    for (diff_manifest.pages) |p_ref| {
        const space_slice = getSpaceSlice(files, p_ref.space, accessor).?;
        const offset = @as(usize, p_ref.page_index) * page_size;
        const page_bytes = objects.get(objects.context, p_ref.object).?;
        @memcpy(space_slice[offset .. offset + page_size], page_bytes);
    }
    if (diff_manifest.pages.len > 0) {
        files.store.notifyCodeRanges();
        if (files.pair) |pair| if (pair.store) |s| s.notifyCodeRanges();
    }
}
