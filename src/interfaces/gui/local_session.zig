//! The shell's local session (RA8EMU-1092, ADR 0004 step 6): the image's
//! session served in-process, so `ra8_gui IMAGE` starts no second process.
//! Its requests cross the worker's typed mailbox (local_native_link.zig)
//! and the worker's thread serves them; RPC over a pipe or socket is only
//! for a remote session.
const std = @import("std");
const board_camera = @import("ra8_session").board.camera;
const served_setup = @import("ra8_rpc").served_setup;

pub const LocalSession = struct {
    /// Stable allocation lets a replacement finish before the old run closes.
    setup: *served_setup.Served,
    allocator: std.mem.Allocator,

    /// Open `elf_path` and serve it, on the board profile `board_profile`
    /// names (RA8EMU-1152; null is the shipped default). The host and the
    /// context point into `self`, so it stays put until `deinit`.
    pub fn open(self: *LocalSession, allocator: std.mem.Allocator, io: std.Io, elf_path: []const u8, board_profile: ?[]const u8) !void {
        try self.openWith(allocator, io, elf_path, board_profile, null);
    }

    /// `open` with a history to record, for a window whose branch tree and
    /// state diff have something to show.
    pub fn openWith(self: *LocalSession, allocator: std.mem.Allocator, io: std.Io, elf_path: []const u8, board_profile: ?[]const u8, history: ?served_setup.HistoryOpts) !void {
        const setup = try allocator.create(served_setup.Served);
        errdefer allocator.destroy(setup);
        try setup.open(allocator, io, elf_path, board_profile, history);
        self.* = .{ .setup = setup, .allocator = allocator };
    }

    /// The window's own session: it records its history, on disk under the
    /// app's per-user directory `dir` when there is one and can be used,
    /// otherwise in memory, so the branch tree, the filmstrip and the state
    /// diff have a history to show. The on-disk session is ephemeral and
    /// goes when the session closes.
    pub fn openRecording(self: *LocalSession, allocator: std.mem.Allocator, io: std.Io, elf_path: []const u8, board_profile: ?[]const u8, dir: ?[]const u8) !void {
        return self.openRecordingApps(allocator, io, elf_path, board_profile, dir, &.{});
    }

    /// Stage app bytes before recording begins, including the RAM fallback.
    pub fn openRecordingApps(self: *LocalSession, allocator: std.mem.Allocator, io: std.Io, elf_path: []const u8, board_profile: ?[]const u8, dir: ?[]const u8, apps: []const []const u8) !void {
        return self.openRecordingPair(allocator, io, elf_path, board_profile, dir, apps, null);
    }

    /// Both core images are installed before the recording root and checkpoint.
    pub fn openRecordingPair(self: *LocalSession, allocator: std.mem.Allocator, io: std.Io, elf_path: []const u8, board_profile: ?[]const u8, dir: ?[]const u8, apps: []const []const u8, cpu1: ?[]const u8) !void {
        const setup = try allocator.create(served_setup.Served);
        errdefer allocator.destroy(setup);
        const second: ?served_setup.SecondImage = if (cpu1) |path| .{ .path = path } else null;
        var card: @import("ra8_rpc").served_card.Options = .{};
        for (apps) |path| try card.addApp(path);
        if (dir) |base| {
            const root = try std.fmt.allocPrint(allocator, "{s}{c}history", .{ base, std.fs.path.sep });
            defer allocator.free(root);
            if (setup.openInputs(allocator, io, elf_path, board_profile, .{ .root = root }, second, .{ .card = card })) |_| {
                self.* = .{ .setup = setup, .allocator = allocator };
                return;
            } else |_| {}
        }
        try setup.openInputs(allocator, io, elf_path, board_profile, .{}, second, .{ .card = card });
        self.* = .{ .setup = setup, .allocator = allocator };
    }

    /// Bring up cpu1 from `path` in the already-open session (RA8EMU-1192).
    pub fn openSecond(self: *LocalSession, path: []const u8) !void {
        try self.setup.openSecond(path);
    }

    /// Sample a preview frame from the board's camera source (RA8EMU-1180).
    pub fn cameraPreview(self: *LocalSession) ?board_camera.Preview {
        return board_camera.preview(self.setup.owner.board());
    }

    pub fn deinit(self: *LocalSession) void {
        self.setup.deinit();
        self.allocator.destroy(self.setup);
    }
};
