//! A Y4M clip on disk for `--camera-source video:PATH[,loop]` (RA8EMU-499),
//! read here in ra8_host so the camera model never opens a file
//! (RA8EMU-1011).
//!
//! The header is read and every frame's offset indexed when the run starts,
//! so a missing, empty or unsupported clip stops the run before the firmware
//! boots. Frames stay on disk; only the one a capture needs is read and
//! decoded. The frame is chosen by emulated time, never wall-clock time, so
//! a run at any speed sees the same frame at the same emulated instant. Past
//! the last frame the clip wraps with `,loop` and holds its last frame
//! otherwise. A trailing frame cut short by the end of the file is dropped.
const std = @import("std");
const decoded = @import("decoded_image.zig");
pub const y4m = @import("y4m/header.zig");
pub const yuv = @import("y4m/frame.zig");

/// The longest header or FRAME line read before the line is refused.
const max_line: usize = 256;

pub const Arg = struct { path: []const u8, loop: bool };

/// `PATH` or `PATH,loop`.
pub fn parseArg(arg: []const u8) Arg {
    const suffix = ",loop";
    if (std.mem.endsWith(u8, arg, suffix)) return .{ .path = arg[0 .. arg.len - suffix.len], .loop = true };
    return .{ .path = arg, .loop = false };
}

/// The frame a capture at `when` emulated ns shows, out of `count`.
pub fn frameAt(fps_num: u32, fps_den: u32, count: usize, loop: bool, when: u64) usize {
    const ordinal = @as(u128, when) * fps_num / (@as(u128, fps_den) * std.time.ns_per_s);
    if (ordinal < count) return @intCast(ordinal);
    if (loop) return @intCast(ordinal % count);
    return count - 1;
}

pub const Clip = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    header: y4m.Header,
    loop: bool,
    /// Where each whole frame's planes start in the file.
    offsets: []u64,
    planes: []u8,
    image: decoded.Image,
    shown: ?usize = null,

    pub fn load(allocator: std.mem.Allocator, io: std.Io, arg: []const u8) !*Clip {
        const parsed = parseArg(arg);
        const file = try std.Io.Dir.cwd().openFile(io, parsed.path, .{});
        errdefer file.close(io);
        var line: [max_line]u8 = undefined;
        const first = try readLine(io, file, 0, &line);
        const header = try y4m.parse(first.text);
        const offsets = try index(allocator, io, file, header, first.next);
        errdefer allocator.free(offsets);
        const image = try decoded.Image.alloc(allocator, header.width, header.height);
        errdefer image.deinit(allocator);
        const planes = try allocator.alloc(u8, @intCast(header.frameBytes()));
        errdefer allocator.free(planes);
        const self = try allocator.create(Clip);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .file = file,
            .header = header,
            .loop = parsed.loop,
            .offsets = offsets,
            .planes = planes,
            .image = image,
        };
        @memset(image.pixels, 0);
        return self;
    }

    /// The frame a capture at `when` shows.
    pub fn pick(self: *const Clip, when: u64) usize {
        return frameAt(self.header.fps_num, self.header.fps_den, self.offsets.len, self.loop, when);
    }

    /// Decode frame `at` unless it is already the one shown. A read that
    /// comes back short keeps the previous picture rather than half a frame.
    fn show(self: *Clip, at: usize) void {
        if (self.shown == at) return;
        const got = self.file.readPositionalAll(self.io, self.planes, self.offsets[at]) catch return;
        if (got != self.planes.len) return;
        yuv.toRgb(self.header, self.planes, self.image.pixels);
        self.shown = at;
    }

    /// The frame a capture armed at `when` emulated ns shows.
    pub fn picture(self: *Clip, when: u64) decoded.Image {
        self.show(self.pick(when));
        return self.image;
    }

    pub fn close(self: *Clip) void {
        const allocator = self.allocator;
        self.file.close(self.io);
        allocator.free(self.offsets);
        allocator.free(self.planes);
        self.image.deinit(allocator);
        allocator.destroy(self);
    }
};

const Line = struct { text: []const u8, next: u64 };

/// One newline-ended line at `at`, and the offset just past it.
fn readLine(io: std.Io, file: std.Io.File, at: u64, buffer: *[max_line]u8) !Line {
    const got = try file.readPositionalAll(io, buffer, at);
    const end = std.mem.indexOfScalar(u8, buffer[0..got], '\n') orelse return error.BadHeader;
    return .{ .text = buffer[0..end], .next = at + end + 1 };
}

/// The plane offset of every whole frame from `start` to the end of file.
fn index(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, header: y4m.Header, start: u64) ![]u64 {
    const size = try file.length(io);
    const bytes = header.frameBytes();
    var offsets: std.ArrayList(u64) = .empty;
    errdefer offsets.deinit(allocator);
    var at = start;
    var line: [max_line]u8 = undefined;
    while (at < size) {
        const next = try readLine(io, file, at, &line);
        if (!std.mem.startsWith(u8, next.text, "FRAME")) return error.BadHeader;
        if (next.next + bytes > size) break;
        try offsets.append(allocator, next.next);
        at = next.next + bytes;
    }
    if (offsets.items.len == 0) return error.Truncated;
    return offsets.toOwnedSlice(allocator);
}
