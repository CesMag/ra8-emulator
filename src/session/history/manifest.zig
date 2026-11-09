//! Merkle manifest codec and diffing for content-addressed checkpoints.
//!
//! A manifest represents a complete point-in-time state of the machine:
//! 4 KiB paged spaces (CPU0/CPU1 memory regions, NOR flash, SD, e-ink) and
//! non-paged state blobs (registers, timers, scheduler stretch, debug units).
//! The Merkle root binds all page and blob hashes cryptographically.
const std = @import("std");
const ObjectId = @import("object_id.zig").ObjectId;
const position_mod = @import("position.zig");
const Position = position_mod.Position;
const Crc32c = std.hash.crc.@"CRC-32/ISCSI";

pub const magic: [8]u8 = "RA8MAN1\x00".*;
pub const version: u32 = 1;

pub const SpaceId = enum(u8) {
    cpu0_mram = 0,
    cpu0_dtcm = 1,
    cpu0_sram = 2,
    cpu0_sdram = 3,
    cpu0_ppb = 4,
    cpu1_mram = 5,
    cpu1_dtcm = 6,
    cpu1_ppb = 7,
    store_extra = 8,
    nor_flash = 9,
    sd_card = 10,
    eink_buffer = 11,
    fabric_state = 12,
    cpu_registers = 13,
    system_timers = 14,
    debug_units = 15,
    attachments = 16,
    checkpoint_picture = 17,
    stretch_state = 18,
    board_periph = 19,
    run_state = 20,
    _,
};

pub const PageRef = struct {
    space: SpaceId,
    page_index: u32,
    object: ObjectId,

    pub fn eql(self: PageRef, other: PageRef) bool {
        return self.space == other.space and self.page_index == other.page_index and self.object.eql(other.object);
    }
};

pub const BlobRef = struct {
    space: SpaceId,
    object: ObjectId,
    size: u32,

    pub fn eql(self: BlobRef, other: BlobRef) bool {
        return self.space == other.space and self.size == other.size and self.object.eql(other.object);
    }
};

pub const Manifest = struct {
    position: Position,
    checkpoint_id: u32,
    picture: ?ObjectId = null,
    pages: []PageRef,
    blobs: []BlobRef,
    root_hash: ObjectId,

    pub fn deinit(self: *Manifest, allocator: std.mem.Allocator) void {
        allocator.free(self.pages);
        allocator.free(self.blobs);
        self.* = undefined;
    }
};

pub const ManifestDiff = struct {
    pages: []PageRef,
    blobs: []BlobRef,

    pub fn deinit(self: *ManifestDiff, allocator: std.mem.Allocator) void {
        allocator.free(self.pages);
        allocator.free(self.blobs);
        self.* = undefined;
    }
};

pub const Error = error{
    BadMagic,
    BadVersion,
    Truncated,
    BadCrc,
    BadMerkleRoot,
    OutOfMemory,
};

/// 32-character hex name of the manifest object kept beside a checkpoint
/// object: the manifest names the checkpoint's page and blob objects.
pub fn objectName(object: [16]u8) [32]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("ra8-manifest-v1:");
    hasher.update(&object);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    var name: [32]u8 = undefined;
    for (digest[0..16], 0..) |byte, i| {
        _ = std.fmt.bufPrint(name[i * 2 ..][0..2], "{x:0>2}", .{byte}) catch unreachable;
    }
    return name;
}

fn encodePage(entry: *[21]u8, page: PageRef) void {
    entry[0] = @backingInt(page.space);
    std.mem.writeInt(u32, entry[1..5], page.page_index, .little);
    @memcpy(entry[5..21], &page.object.bytes);
}

/// Computes the 128-bit Blake3 Merkle root over all manifest fields, pages and blobs.
pub fn computeMerkleRoot(
    position: Position,
    checkpoint_id: u32,
    picture: ?ObjectId,
    pages: []const PageRef,
    blobs: []const BlobRef,
) ObjectId {
    var hasher = std.crypto.hash.Blake3.init(.{});
    // 1. Position & metadata
    var pos_buf: [position_mod.encoded_len]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&pos_buf);
    position_mod.encode(&stream, position) catch unreachable;
    hasher.update(&pos_buf);
    var meta: [8]u8 = undefined;
    std.mem.writeInt(u32, meta[0..4], checkpoint_id, .little);
    meta[4] = if (picture != null) 1 else 0;
    meta[5] = 0;
    meta[6] = 0;
    meta[7] = 0;
    hasher.update(&meta);
    if (picture) |pic| hasher.update(&pic.bytes);
    // 2. Pages
    var p_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &p_buf, @intCast(pages.len), .little);
    hasher.update(&p_buf);
    var batch: [21 * 390]u8 = undefined;
    var used: usize = 0;
    for (pages) |page| {
        if (used + 21 > batch.len) {
            hasher.update(batch[0..used]);
            used = 0;
        }
        encodePage(batch[used..][0..21], page);
        used += 21;
    }
    if (used > 0) hasher.update(batch[0..used]);
    // 3. Blobs
    var b_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &b_buf, @intCast(blobs.len), .little);
    hasher.update(&b_buf);
    for (blobs) |blob| {
        var entry: [21]u8 = undefined;
        entry[0] = @backingInt(blob.space);
        std.mem.writeInt(u32, entry[1..5], blob.size, .little);
        @memcpy(entry[5..21], &blob.object.bytes);
        hasher.update(&entry);
    }
    var full: [32]u8 = undefined;
    hasher.final(&full);
    return .{ .bytes = full[0..16].* };
}

/// Encodes a Manifest to writer with Castagnoli CRC32-C trailer.
pub fn encode(manifest: *const Manifest, writer: anytype) !void {
    var crc = Crc32c.init();
    try writer.writeAll(&magic);
    crc.update(&magic);
    var head: [4]u8 = undefined;
    std.mem.writeInt(u32, &head, version, .little);
    try writer.writeAll(&head);
    crc.update(&head);
    var pos_buf: [position_mod.encoded_len]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&pos_buf);
    try position_mod.encode(&stream, manifest.position);
    try writer.writeAll(&pos_buf);
    crc.update(&pos_buf);
    var meta: [5]u8 = undefined;
    std.mem.writeInt(u32, meta[0..4], manifest.checkpoint_id, .little);
    meta[4] = if (manifest.picture != null) 1 else 0;
    try writer.writeAll(&meta);
    crc.update(&meta);
    if (manifest.picture) |pic| {
        try writer.writeAll(&pic.bytes);
        crc.update(&pic.bytes);
    }
    var p_count: [4]u8 = undefined;
    std.mem.writeInt(u32, &p_count, @intCast(manifest.pages.len), .little);
    try writer.writeAll(&p_count);
    crc.update(&p_count);
    var batch: [21 * 390]u8 = undefined;
    var used: usize = 0;
    for (manifest.pages) |page| {
        if (used + 21 > batch.len) {
            try writer.writeAll(batch[0..used]);
            crc.update(batch[0..used]);
            used = 0;
        }
        encodePage(batch[used..][0..21], page);
        used += 21;
    }
    if (used > 0) {
        try writer.writeAll(batch[0..used]);
        crc.update(batch[0..used]);
    }

    var b_count: [4]u8 = undefined;
    std.mem.writeInt(u32, &b_count, @intCast(manifest.blobs.len), .little);
    try writer.writeAll(&b_count);
    crc.update(&b_count);

    for (manifest.blobs) |blob| {
        var entry: [21]u8 = undefined;
        entry[0] = @backingInt(blob.space);
        std.mem.writeInt(u32, entry[1..5], blob.size, .little);
        @memcpy(entry[5..21], &blob.object.bytes);
        try writer.writeAll(&entry);
        crc.update(&entry);
    }

    try writer.writeAll(&manifest.root_hash.bytes);
    crc.update(&manifest.root_hash.bytes);

    var trailer: [4]u8 = undefined;
    std.mem.writeInt(u32, &trailer, crc.final(), .little);
    try writer.writeAll(&trailer);
}

/// Decodes a manifest from serialized bytes, validating magic, CRC and Merkle root.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!Manifest {
    const min_len = magic.len + 4 + position_mod.encoded_len + 5 + 4 + 4 + 16 + 4;
    if (bytes.len < min_len) return Error.Truncated;

    if (!std.mem.eql(u8, bytes[0..magic.len], &magic)) return Error.BadMagic;
    const v = std.mem.readInt(u32, bytes[magic.len..][0..4], .little);
    if (v != version) return Error.BadVersion;

    var crc = Crc32c.init();
    crc.update(bytes[0 .. bytes.len - 4]);
    const stored_crc = std.mem.readInt(u32, bytes[bytes.len - 4 ..][0..4], .little);
    if (crc.final() != stored_crc) return Error.BadCrc;

    var at: usize = magic.len + 4;

    var p_at: usize = 0;
    const pos = position_mod.decode(bytes[at .. at + position_mod.encoded_len], &p_at) catch return Error.Truncated;
    at += position_mod.encoded_len;

    const checkpoint_id = std.mem.readInt(u32, bytes[at..][0..4], .little);
    at += 4;
    const has_pic = bytes[at] != 0;
    at += 1;

    var picture: ?ObjectId = null;
    if (has_pic) {
        if (at + 16 > bytes.len - 4) return Error.Truncated;
        picture = ObjectId{ .bytes = bytes[at..][0..16].* };
        at += 16;
    }

    if (at + 4 > bytes.len - 4) return Error.Truncated;
    const pages_count = std.mem.readInt(u32, bytes[at..][0..4], .little);
    at += 4;

    const pages = try allocator.alloc(PageRef, pages_count);
    errdefer allocator.free(pages);

    for (0..pages_count) |i| {
        if (at + 21 > bytes.len - 4) return Error.Truncated;
        pages[i] = .{
            .space = @fromBackingInt(@intCast(bytes[at])),
            .page_index = std.mem.readInt(u32, bytes[at + 1 ..][0..4], .little),
            .object = .{ .bytes = bytes[at + 5 ..][0..16].* },
        };
        at += 21;
    }

    if (at + 4 > bytes.len - 4) return Error.Truncated;
    const blobs_count = std.mem.readInt(u32, bytes[at..][0..4], .little);
    at += 4;

    const blobs = try allocator.alloc(BlobRef, blobs_count);
    errdefer allocator.free(blobs);

    for (0..blobs_count) |i| {
        if (at + 21 > bytes.len - 4) return Error.Truncated;
        blobs[i] = .{
            .space = @fromBackingInt(@intCast(bytes[at])),
            .size = std.mem.readInt(u32, bytes[at + 1 ..][0..4], .little),
            .object = .{ .bytes = bytes[at + 5 ..][0..16].* },
        };
        at += 21;
    }

    if (at + 16 > bytes.len - 4) return Error.Truncated;
    const root_hash = ObjectId{ .bytes = bytes[at..][0..16].* };

    const expected_root = computeMerkleRoot(pos, checkpoint_id, picture, pages, blobs);
    if (!root_hash.eql(expected_root)) return Error.BadMerkleRoot;

    return .{
        .position = pos,
        .checkpoint_id = checkpoint_id,
        .picture = picture,
        .pages = pages,
        .blobs = blobs,
        .root_hash = root_hash,
    };
}

pub fn pageOrder(a: PageRef, b: PageRef) std.math.Order {
    const sa = @backingInt(a.space);
    const sb = @backingInt(b.space);
    if (sa < sb) return .lt;
    if (sa > sb) return .gt;
    return std.math.order(a.page_index, b.page_index);
}

/// Diffs two manifests, returning the list of differing pages and blobs in target.
/// Exploits the canonical sorting of PageRef to achieve strictly O(N) merge diffing.
pub fn diff(
    allocator: std.mem.Allocator,
    current: ?*const Manifest,
    target: *const Manifest,
) !ManifestDiff {
    var p_list: std.ArrayList(PageRef) = .empty;
    defer p_list.deinit(allocator);

    if (current) |cur| {
        var c_idx: usize = 0;
        var t_idx: usize = 0;
        while (t_idx < target.pages.len) {
            const t_page = target.pages[t_idx];
            if (c_idx >= cur.pages.len) {
                try p_list.append(allocator, t_page);
                t_idx += 1;
                continue;
            }
            const c_page = cur.pages[c_idx];
            const ord = pageOrder(t_page, c_page);
            switch (ord) {
                .lt => {
                    try p_list.append(allocator, t_page);
                    t_idx += 1;
                },
                .gt => {
                    c_idx += 1;
                },
                .eq => {
                    if (!t_page.object.eql(c_page.object)) {
                        try p_list.append(allocator, t_page);
                    }
                    t_idx += 1;
                    c_idx += 1;
                },
            }
        }
    } else {
        for (target.pages) |t_page| {
            try p_list.append(allocator, t_page);
        }
    }

    var b_list: std.ArrayList(BlobRef) = .empty;
    defer b_list.deinit(allocator);

    for (target.blobs) |t_blob| {
        const differs = if (current) |cur| blk: {
            const cur_blob = findBlob(cur.blobs, t_blob.space);
            break :blk cur_blob == null or !cur_blob.?.object.eql(t_blob.object) or cur_blob.?.size != t_blob.size;
        } else true;

        if (differs) try b_list.append(allocator, t_blob);
    }

    return .{
        .pages = try p_list.toOwnedSlice(allocator),
        .blobs = try b_list.toOwnedSlice(allocator),
    };
}

fn findBlob(blobs: []const BlobRef, space: SpaceId) ?BlobRef {
    for (blobs) |b| {
        if (b.space == space) return b;
    }
    return null;
}
