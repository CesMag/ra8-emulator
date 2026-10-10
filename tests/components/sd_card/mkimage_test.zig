//! RA8EMU-563: a FAT32 image built from a host folder is the same bytes
//! every time, and the SDHI card reads every file back from it.
const std = @import("std");
const io = std.testing.io;
const ra8 = @import("ra8");
const mk = ra8.components.sd_card.mkimage;
const sd_image = ra8.components.sd_card.image;
const disk_file = ra8.host.disk_file;
const Folder = ra8.host.folder.Folder;
const card = ra8.components.sd_card.bus_card;
const fat32 = @import("fat32_reader.zig");

const A = std.testing.allocator;

/// A folder of books, comics and music: short and long names, a non-ASCII
/// name, an empty file, a file spanning many clusters, a dotfile to skip,
/// and a directory big enough to need more than one cluster.
fn fixture(dir: std.Io.Dir, reverse: bool) !void {
    try dir.createDirPath(io, "books");
    try dir.createDirPath(io, "comics/Issue Set");
    var i: usize = 0;
    while (i < 24) : (i += 1) {
        const n = if (reverse) 23 - i else i;
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "music/Track {d:0>2} - A Long Song Title.mp3", .{n});
        try dir.createDirPath(io, "music");
        var body: [300]u8 = undefined;
        for (&body, 0..) |*b, k| b.* = @truncate(n * 7 + k);
        try dir.writeFile(io, .{ .sub_path = name, .data = body[0 .. 100 + n * 8] });
    }
    var big: [5000]u8 = undefined;
    for (&big, 0..) |*b, k| b.* = @truncate(k * 31 + 5);
    try dir.writeFile(io, .{ .sub_path = "books/Moby Dick - Whale.epub", .data = &big });
    try dir.writeFile(io, .{ .sub_path = "books/café.txt", .data = "bonjour\n" });
    try dir.writeFile(io, .{ .sub_path = "README.TXT", .data = "fixture\n" });
    try dir.writeFile(io, .{ .sub_path = "EMPTY.DAT", .data = "" });
    try dir.writeFile(io, .{ .sub_path = "comics/Issue Set/Issue 01.cbz", .data = big[0..1500] });
    try dir.writeFile(io, .{ .sub_path = ".DS_Store", .data = "junk" });
}

fn buildBytes(dir: std.Io.Dir, out: std.Io.Dir, name: []const u8) ![]u8 {
    var img = sd_image.Image.init(A);
    defer img.deinit();
    _ = try mk.build(A, &img, Folder.of(io, dir), "BOOKS");
    try disk_file.replace(io, out, name, &img);
    return out.readFileAlloc(io, name, A, .unlimited);
}

const CardSource = struct {
    unit: *card.Card,
    pub fn read(self: CardSource, lba: u32, out: *[512]u8) bool {
        return self.unit.read(lba, out);
    }
};

/// Every file under `host` matches the image's copy, read through the card.
fn matchTree(r: *const fat32.Reader(CardSource), cluster: u32, host: std.Io.Dir) !usize {
    const items = try fat32.list(r, A, cluster);
    defer fat32.freeItems(A, items);
    var count: usize = 0;
    var it = host.iterate();
    while (try it.next(io)) |entry| {
        if (entry.name[0] == '.') continue;
        const item = for (items) |item| {
            if (std.mem.eql(u8, item.name, entry.name)) break item;
        } else return error.Missing;
        if (entry.kind == .directory) {
            try std.testing.expect(item.is_dir);
            var sub = try host.openDir(io, entry.name, .{ .iterate = true });
            defer sub.close(io);
            count += try matchTree(r, item.cluster, sub);
            continue;
        }
        const want = try host.readFileAlloc(io, entry.name, A, .limited(1 << 20));
        defer A.free(want);
        const got = try r.chain(A, item.cluster, item.size);
        defer A.free(got);
        try std.testing.expectEqualSlices(u8, want, got);
        count += 1;
    }
    for (items) |item| if (std.mem.eql(u8, item.name, ".DS_Store")) return error.DotfileKept;
    return count;
}

test "the SDHI card reads every file of the folder back from the image" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    var src = try tmp.dir.openDir(io, "src", .{ .iterate = true });
    defer src.close(io);
    try fixture(src, false);
    const bytes = try buildBytes(src, tmp.dir, "a.img");
    defer A.free(bytes);
    var unit = card.Card.init(A);
    defer unit.deinit();
    try unit.loadBytes(bytes);
    const r = try fat32.Reader(CardSource).open(.{ .unit = &unit });
    try std.testing.expectEqual(@as(usize, 29), try matchTree(&r, r.root, src));
}

test "the same folder, written in another order, builds the same bytes" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "one");
    try tmp.dir.createDirPath(io, "two");
    var one = try tmp.dir.openDir(io, "one", .{ .iterate = true });
    defer one.close(io);
    var two = try tmp.dir.openDir(io, "two", .{ .iterate = true });
    defer two.close(io);
    try fixture(one, false);
    try fixture(two, true);
    const a = try buildBytes(one, tmp.dir, "a.img");
    defer A.free(a);
    const b = try buildBytes(two, tmp.dir, "b.img");
    defer A.free(b);
    const again = try buildBytes(one, tmp.dir, "c.img");
    defer A.free(again);
    try std.testing.expectEqualSlices(u8, a, b);
    try std.testing.expectEqualSlices(u8, a, again);
}

test "a symlink is refused rather than left out" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "A.TXT", .data = "a" });
    try tmp.dir.symLink(io, "A.TXT", "link", .{});
    var img = sd_image.Image.init(A);
    defer img.deinit();
    try std.testing.expectError(error.UnsupportedEntry, mk.build(A, &img, Folder.of(io, tmp.dir), "X"));
}
