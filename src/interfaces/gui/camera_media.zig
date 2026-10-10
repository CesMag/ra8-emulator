//! The pictures and clips the camera panel can offer (RA8EMU-500): the
//! files in the project directory the image and video sources would open.
//! Like those sources, a file is judged by its first bytes, never its name:
//! a PNG, BMP or PPM is a picture, a YUV4MPEG2 stream is a clip. Whatever
//! else sits in the directory, and anything that will not open, is left out.
const std = @import("std");
const png = @import("ra8_host").camera.png;
const bmp = @import("ra8_host").camera.bmp;
const ppm = @import("ra8_host").camera.ppm;
const y4m = @import("ra8_host").camera.y4m;

/// How many leading bytes it takes to tell the kinds apart.
pub const sniff_len = 16;

pub const Kind = enum { image, video };

/// What the first bytes of a file make it, or null for neither.
pub fn classify(head: []const u8) ?Kind {
    if (png.claims(head) or bmp.claims(head) or ppm.claims(head)) return .image;
    if (std.mem.startsWith(u8, head, y4m.magic)) return .video;
    return null;
}

/// The names found, each list sorted by name. Owns every name.
pub const Media = struct {
    allocator: std.mem.Allocator,
    images: [][]u8,
    videos: [][]u8,

    pub fn of(self: Media, kind: Kind) []const []u8 {
        return switch (kind) {
            .image => self.images,
            .video => self.videos,
        };
    }

    pub fn deinit(self: *Media) void {
        freeNames(self.allocator, self.images);
        freeNames(self.allocator, self.videos);
        self.* = undefined;
    }
};

/// The pictures and clips directly in `dir`, which must be iterable.
pub fn list(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !Media {
    var images: std.ArrayList([]u8) = .empty;
    defer images.deinit(allocator);
    errdefer for (images.items) |name| allocator.free(name);
    var videos: std.ArrayList([]u8) = .empty;
    defer videos.deinit(allocator);
    errdefer for (videos.items) |name| allocator.free(name);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const kind = sniff(io, dir, entry.name) orelse continue;
        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        try (if (kind == .image) &images else &videos).append(allocator, name);
    }
    const found_images = try images.toOwnedSlice(allocator);
    errdefer freeNames(allocator, found_images);
    const found_videos = try videos.toOwnedSlice(allocator);
    sortNames(found_images);
    sortNames(found_videos);
    return .{ .allocator = allocator, .images = found_images, .videos = found_videos };
}

fn sniff(io: std.Io, dir: std.Io.Dir, name: []const u8) ?Kind {
    const file = dir.openFile(io, name, .{}) catch return null;
    defer file.close(io);
    var head: [sniff_len]u8 = undefined;
    const got = file.readPositionalAll(io, &head, 0) catch return null;
    return classify(head[0..got]);
}

fn sortNames(names: [][]u8) void {
    std.mem.sort([]u8, names, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
}

fn freeNames(allocator: std.mem.Allocator, names: [][]u8) void {
    for (names) |name| allocator.free(name);
    allocator.free(names);
}
