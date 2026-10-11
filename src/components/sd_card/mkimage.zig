//! Build a FAT32 card image from a host folder (RA8EMU-563), the same bytes
//! every time: names sorted, one fixed timestamp (sd_dirent.stamp), clusters
//! handed out in walk order (a directory's own clusters, then its children),
//! every file contiguous, and the card the smallest whole-MiB FAT32 size the
//! folder fits on. Dotfiles are skipped; links and other kinds are refused,
//! so the image never quietly differs from the folder.
//!
//! The folder is whatever the application passes (host/folder.zig for a
//! real one, RA8EMU-1020): `list(allocator)` giving entries with `name` and
//! `kind` (.file, .directory, anything else), `free(allocator, entries)`,
//! `sub(name)` and `close()`, `size(name)` and `read(allocator, name)`.
const std = @import("std");
const image = @import("image.zig");
const fat = @import("fat.zig");
const format = @import("format/format.zig");
const dirent = @import("dirent.zig");

pub const Error = error{ UnsupportedEntry, FileTooLarge, TooManyNames, NoCardFits, WriteRefused };

/// What a build laid down.
pub const Built = struct {
    volume: format.Volume,
    files: u32,
    dirs: u32,
    used_clusters: u32,
};

const Item = struct { name: []const u8, is_dir: bool };

/// Format `img` and fill it from `folder`. `img` is resized to the card chosen.
pub fn build(allocator: std.mem.Allocator, img: *image.Image, folder: anytype, label: []const u8) !Built {
    var mib = format.smallestCardMib(.fat32) orelse return error.NoCardFits;
    while (true) : (mib *= 2) {
        if (mib > format.search.max_mib) return error.NoCardFits;
        const layout = try format.solve(.fat32, mib * format.search.sectors_per_mib);
        const bytes = layout.sectors_per_cluster * fat.sector_bytes;
        const need = 1 + try clustersIn(allocator, folder, bytes, true);
        if (need <= layout.clusters) break;
    }
    if (!img.resize(mib * format.search.sectors_per_mib)) return error.WriteRefused;
    const volume = try format.apply(img, .fat32, label);
    var w = try Writer.init(allocator, img, volume.layout);
    defer allocator.free(w.table);
    _ = try w.writeDir(folder, 0, label);
    try w.finish();
    return .{ .volume = volume, .files = w.files, .dirs = w.dirs, .used_clusters = w.next - fat.value.root_cluster };
}

/// The directory's entries, dotfiles left out, sorted by name bytes.
fn listed(allocator: std.mem.Allocator, folder: anytype) ![]Item {
    const entries = try folder.list(allocator);
    defer @TypeOf(folder).free(allocator, entries);
    var items: std.ArrayList(Item) = .empty;
    errdefer {
        for (items.items) |item| allocator.free(item.name);
        items.deinit(allocator);
    }
    for (entries) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const is_dir = switch (entry.kind) {
            .directory => true,
            .file => false,
            else => return error.UnsupportedEntry,
        };
        try items.append(allocator, .{ .name = try allocator.dupe(u8, entry.name), .is_dir = is_dir });
    }
    std.mem.sort(Item, items.items, {}, struct {
        fn less(_: void, a: Item, b: Item) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.less);
    return items.toOwnedSlice(allocator);
}

fn freeItems(allocator: std.mem.Allocator, items: []Item) void {
    for (items) |item| allocator.free(item.name);
    allocator.free(items);
}

/// Entry slots a directory needs: its own two (dot pair, or the root's label
/// plus one spare to keep the count alike) and every child's.
fn slotsFor(items: []const Item) !usize {
    var count: usize = 2;
    for (items) |item| count += try dirent.slots(item.name);
    return count;
}

fn clustersOf(size: u64, cluster_bytes: u64) u32 {
    return @intCast((size + cluster_bytes - 1) / cluster_bytes);
}

/// Clusters the folder takes at `cluster_bytes`, root's own clusters beyond
/// the first excluded when `root` (the caller counts cluster 2).
fn clustersIn(allocator: std.mem.Allocator, folder: anytype, cluster_bytes: u64, root: bool) anyerror!u32 {
    const items = try listed(allocator, folder);
    defer freeItems(allocator, items);
    const own = clustersOf((try slotsFor(items)) * dirent.bytes, cluster_bytes);
    var total: u32 = if (root) own - 1 else own;
    for (items) |item| {
        if (item.is_dir) {
            var sub = try folder.sub(item.name);
            defer sub.close();
            total += try clustersIn(allocator, sub, cluster_bytes, false);
        } else {
            total += clustersOf(try folder.size(item.name), cluster_bytes);
        }
    }
    return total;
}

const Writer = struct {
    allocator: std.mem.Allocator,
    img: *image.Image,
    layout: fat.Layout,
    table: []u32,
    next: u32 = fat.value.root_cluster,
    files: u32 = 0,
    dirs: u32 = 0,

    fn init(allocator: std.mem.Allocator, img: *image.Image, layout: fat.Layout) !Writer {
        const table = try allocator.alloc(u32, layout.clusters + 2);
        @memset(table, 0);
        table[0] = fat.value.fat32_entry0;
        table[1] = fat.value.fat32_end_of_chain;
        return .{ .allocator = allocator, .img = img, .layout = layout, .table = table };
    }

    fn clusterBytes(self: *const Writer) usize {
        return self.layout.sectors_per_cluster * fat.sector_bytes;
    }

    fn sectorOf(self: *const Writer, cluster: u32) u32 {
        const data = self.layout.reserved_sectors + format.rule.fats * self.layout.fat_sectors;
        return data + (cluster - 2) * self.layout.sectors_per_cluster;
    }

    /// A contiguous chain of `count` clusters, or cluster 0 for none.
    fn take(self: *Writer, count: u32) u32 {
        if (count == 0) return 0;
        const first = self.next;
        var c = first;
        while (c < first + count - 1) : (c += 1) self.table[c] = c + 1;
        self.table[c] = fat.value.fat32_end_of_chain;
        self.next = first + count;
        return first;
    }

    /// Lay `bytes` down from `first`; the chain is contiguous, so sectors run on.
    fn writeAt(self: *Writer, first: u32, bytes: []const u8) Error!void {
        if (bytes.len == 0) return;
        var sector = self.sectorOf(first);
        var at: usize = 0;
        while (at < bytes.len) : ({
            at += fat.sector_bytes;
            sector += 1;
        }) {
            var block: fat.Sector = @splat(0);
            const n = @min(fat.sector_bytes, bytes.len - at);
            @memcpy(block[0..n], bytes[at..][0..n]);
            if (std.mem.allEqual(u8, &block, 0)) continue;
            if (!self.img.write(sector, &block)) return error.WriteRefused;
        }
    }

    /// Write one directory and everything under it; return its first cluster.
    /// `parent` is 0 for the root, which carries the volume label instead of
    /// the dot pair.
    fn writeDir(self: *Writer, folder: anytype, parent: u32, label: []const u8) anyerror!u32 {
        const items = try listed(self.allocator, folder);
        defer freeItems(self.allocator, items);
        const slots = try slotsFor(items);
        const first = self.take(clustersOf(slots * dirent.bytes, self.clusterBytes()));
        const entries = try self.allocator.alloc(dirent.Entry, clustersOf(slots * dirent.bytes, self.clusterBytes()) * self.clusterBytes() / dirent.bytes);
        defer self.allocator.free(entries);
        @memset(entries, @as([dirent.bytes]u8, @splat(0)));
        var at: usize = 0;
        if (parent == 0 and first == fat.value.root_cluster) {
            entries[0] = dirent.short(labelName(label), dirent.attr.volume, 0, 0);
            at = 1;
        } else {
            entries[0] = dirent.short(".          ".*, dirent.attr.directory, first, 0);
            const up = if (parent == fat.value.root_cluster) 0 else parent;
            entries[1] = dirent.short("..         ".*, dirent.attr.directory, up, 0);
            at = 2;
        }
        var tail: u32 = 0;
        for (items) |item| {
            if (!dirent.isShort(item.name)) tail += 1;
            if (tail > dirent.max_tail) return error.TooManyNames;
            const cluster, const size, const kind = try self.child(folder, item, first);
            at += try dirent.put(entries[at..], item.name, tail, kind, cluster, size);
        }
        try self.writeAt(first, std.mem.sliceAsBytes(entries));
        self.dirs += 1;
        return first;
    }

    fn child(self: *Writer, folder: anytype, item: Item, here: u32) anyerror!struct { u32, u32, u8 } {
        if (item.is_dir) {
            var sub = try folder.sub(item.name);
            defer sub.close();
            return .{ try self.writeDir(sub, here, ""), 0, dirent.attr.directory };
        }
        const data = try folder.read(self.allocator, item.name);
        defer self.allocator.free(data);
        const first = self.take(clustersOf(data.len, self.clusterBytes()));
        try self.writeAt(first, data);
        self.files += 1;
        return .{ first, @intCast(data.len), dirent.attr.archive };
    }

    /// Both FAT copies, then FSInfo (and its backup) with the true free count.
    fn finish(self: *Writer) Error!void {
        const table_bytes = std.mem.sliceAsBytes(self.table[0..self.next]);
        var copy: u32 = 0;
        while (copy < format.rule.fats) : (copy += 1) {
            const start = self.layout.reserved_sectors + copy * self.layout.fat_sectors;
            try self.writeRaw(start, table_bytes);
        }
        var info = fat.fsInfoSector(self.layout.clusters);
        const used = self.next - fat.value.root_cluster;
        std.mem.writeInt(u32, info[fat.fsinfo_offset.free_clusters..][0..4], self.layout.clusters - used, .little);
        std.mem.writeInt(u32, info[fat.fsinfo_offset.next_free..][0..4], self.next, .little);
        if (!self.img.write(fat.fsinfo_sector, &info)) return error.WriteRefused;
        if (!self.img.write(fat.backup_sector + fat.fsinfo_sector, &info)) return error.WriteRefused;
    }

    fn writeRaw(self: *Writer, sector: u32, bytes: []const u8) Error!void {
        var s = sector;
        var at: usize = 0;
        while (at < bytes.len) : ({
            at += fat.sector_bytes;
            s += 1;
        }) {
            var block: fat.Sector = @splat(0);
            const n = @min(fat.sector_bytes, bytes.len - at);
            @memcpy(block[0..n], bytes[at..][0..n]);
            if (!self.img.write(s, &block)) return error.WriteRefused;
        }
    }
};

/// The volume label as an 11-byte space-padded name.
fn labelName(label: []const u8) [11]u8 {
    var out = @as([11]u8, @splat(' '));
    for (label[0..@min(label.len, 11)], 0..) |c, i| out[i] = std.ascii.toUpper(c);
    return out;
}
