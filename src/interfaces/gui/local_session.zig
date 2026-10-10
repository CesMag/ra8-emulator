//! The shell's local session (RA8EMU-1092, ADR 0004 step 6): the image's
//! session served in-process over the RPC library's loopback, so
//! `ra8_gui IMAGE` starts no second process. The shell's Link talks to
//! `transport()`, and `answer` serves what it sent, once per frame. RPC over
//! a pipe or socket is only for a remote session.
const std = @import("std");
const rpc = @import("ra8_rpc");
const served = @import("../rpc/session_server.zig");
const served_setup = @import("../rpc/served_setup.zig");
const proto = @import("../rpc/session_rpc.zig");
const source_spec = @import("ra8_host").camera.source_spec;
const source_open = @import("ra8_host").camera.source_open;
const hosted = @import("ra8_components").camera.hosted;
const camera_install = @import("ra8_board").camera_install;
const Board = @import("ra8_board").board.Board;

pub const LocalSession = struct {
    setup: served_setup.Served,
    pipes: [2][]u8,
    loop: rpc.Loopback,
    host: served.Host,
    camera: Camera,

    /// Open `elf_path` and serve it. The host and the context point into
    /// `self`, so it stays put until `deinit`.
    pub fn open(self: *LocalSession, allocator: std.mem.Allocator, io: std.Io, elf_path: []const u8) !void {
        try self.setup.open(allocator, io, elf_path);
        errdefer self.setup.deinit();
        const size = 2 * proto.Client.Env.max_frame;
        const to_server = try allocator.alloc(u8, size);
        errdefer allocator.free(to_server);
        const to_shell = try allocator.alloc(u8, size);
        self.pipes = .{ to_server, to_shell };
        self.loop = rpc.Loopback.init(to_server, to_shell);
        self.camera = .{ .board = self.setup.owner.board(), .allocator = allocator, .io = io };
        self.setup.context.camera = .{ .context = &self.camera, .setFn = Camera.set };
        self.host = served.Host.init(self.loop.b(), self.setup.rx, &self.setup.context);
    }

    /// The shell's end of the link.
    pub fn transport(self: *LocalSession) rpc.Transport {
        return self.loop.a();
    }

    /// Answer every frame the shell has sent so far.
    pub fn answer(self: *LocalSession) !void {
        while (try self.host.poll(self.setup.tx) != .idle) {}
    }

    pub fn deinit(self: *LocalSession) void {
        const gpa = self.setup.gpa;
        for (self.pipes) |pipe| gpa.free(pipe);
        self.setup.deinit();
    }
};

/// Opens a camera source for set_camera_source, as `serve` does.
const Camera = struct {
    board: *Board,
    allocator: std.mem.Allocator,
    io: std.Io,

    fn set(context: *anyopaque, spec: source_spec.Spec) anyerror!void {
        const self: *Camera = @ptrCast(@alignCast(context));
        const opened = try source_open.open(self.allocator, self.io, spec);
        const next = try hosted.wrap(self.allocator, opened, &self.board.wire.sensor.format);
        camera_install.install(self.board, next);
    }
};
