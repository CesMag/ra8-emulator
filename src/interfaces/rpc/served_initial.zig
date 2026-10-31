//! Admit frozen startup images before a kept history can recover or write.
const std = @import("std");
const root = @import("ra8_session").history_root;
const Image = @import("served_second.zig").Image;
const history = @import("ra8_host").history;

/// A kept root is immutable; recovery must not move it under another name.
pub fn checkRootRename(io: std.Io, dir: std.Io.Dir) !void {
    var pending = (try history.rename.pending(io, dir)) orelse return;
    defer pending.deinit();
    const note = pending.parsed.value;
    if (note.space == .top and (std.mem.eql(u8, note.from, history.layout.files.root) or std.mem.eql(u8, note.to, history.layout.files.root))) return error.RootRenamePending;
}

pub const Images = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    first: Image,
    second: ?Image,
    owned_first: ?[]u8 = null,
    owned_second: ?[]u8 = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, path: []const u8, bytes: ?[]const u8, second: ?Image) Images {
        return .{ .gpa = gpa, .io = io, .first = if (bytes) |b| .{ .bytes = b } else .{ .path = path }, .second = second };
    }

    pub fn deinit(self: *Images) void {
        if (self.owned_first) |bytes| self.gpa.free(bytes);
        if (self.owned_second) |bytes| self.gpa.free(bytes);
    }

    pub fn firstBytes(self: *const Images) ?[]const u8 {
        return switch (self.first) {
            .path => null,
            .bytes => |bytes| bytes,
        };
    }

    pub fn check(self: *Images, recorded: root.Root) !void {
        if ((recorded.elf1 == null) != (self.second == null)) return error.ImageMismatch;
        const first = try self.read(self.first, &self.owned_first);
        if (!std.mem.eql(u8, &root.identity(first), &recorded.elf0.identity)) return error.ImageMismatch;
        self.first = .{ .bytes = first };
        if (self.second) |image| {
            const second = try self.read(image, &self.owned_second);
            if (!std.mem.eql(u8, &root.identity(second), &recorded.elf1.?.identity)) return error.ImageMismatch;
            self.second = .{ .bytes = second };
        }
    }

    fn read(self: *Images, image: Image, owned: *?[]u8) ![]const u8 {
        switch (image) {
            .bytes => |bytes| return bytes,
            .path => |path| {
                if (owned.*) |bytes| return bytes;
                const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(@import("ra8_session").harness.limits.max_elf_bytes));
                owned.* = bytes;
                return bytes;
            },
        }
    }
};
