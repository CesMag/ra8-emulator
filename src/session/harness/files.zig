//! The run file behind a served session's snapshot and restore
//! (RA8EMU-768), opened on the serving host. The board encodes and decodes
//! it (board/session_state.zig); only this side touches the file
//! (RA8EMU-1020).
const std = @import("std");
const session_state = @import("../board_state.zig");

/// The largest file a restore reads.
const max_bytes = 1 << 30;

pub const StateFile = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    files: *session_state.Files,

    pub fn hook(self: *StateFile) session_state.Hook {
        return .{ .context = self, .saveFn = save, .restoreFn = restore };
    }

    fn save(context: *anyopaque, path: []const u8) anyerror!void {
        const self: *StateFile = @ptrCast(@alignCast(context));
        try self.files.single();
        var out = try std.Io.Dir.cwd().createFile(self.io, path, .{});
        defer out.close(self.io);
        var buffer: [4096]u8 = undefined;
        var file_writer = out.writer(self.io, &buffer);
        try self.files.writeTo(&file_writer.interface);
        try file_writer.interface.flush();
    }

    fn restore(context: *anyopaque, path: []const u8) anyerror!void {
        const self: *StateFile = @ptrCast(@alignCast(context));
        try self.files.single();
        const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(max_bytes));
        defer self.allocator.free(bytes);
        try self.files.readFrom(bytes);
    }
};
