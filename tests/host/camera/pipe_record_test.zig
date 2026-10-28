//! Covers the recorded camera port (src/session/board/recorded_camera.zig)
//! over a real host pipe: frames streamed through a POSIX FIFO into a CEU
//! capture are recorded into the history, and replayed afterwards with the
//! FIFO and its writer gone, landing the same bytes. It runs on Linux and
//! skips elsewhere; the Windows pipe server is covered in pipe/windows_test.zig.
const std = @import("std");
const builtin = @import("builtin");
const ra8 = @import("ra8");
const fixture = @import("../../session/fork_fixture.zig");

const pipe = ra8.host.camera.pipe_input;
const hosted = ra8.components.camera.hosted;
const ceu = ra8.chip.periph.ceu;
const frame_source = ra8.chip.periph.frame_source;
const recorded_camera = ra8.session.board.recorded_camera;
const feeder = ra8.session.history_replay_feeder;
const Store = ra8.chip.core.cpu.memory.store.Store;
const Guest = ra8.chip.core.cpu.memory.guest.Guest;
const gpa = std.testing.allocator;

const frame_base: u32 = ra8.chip.core.memmap.sdram_end - 0x1000;
/// The pipe carries 64x32 rgb24 frames; the CEU captures them as RGB565,
/// 128 bytes a line and 32 lines, which is large enough to be deflated.
const pipe_w = 64;
const pipe_h = 32;
const width: u32 = 128;
const lines: u32 = 32;
const frame_len: usize = width * lines;

fn at(offset: u32) u32 {
    return ceu.win_base + offset;
}

fn picture(shade: u8, out: []u8) void {
    for (out, 0..) |*byte, i| byte.* = shade +% @as(u8, @truncate(i / 7)) *% 5;
}

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = std.c.write(fd, bytes[done..].ptr, bytes.len - done);
        if (n < 0) return error.WriteFailed;
        done += @intCast(n);
    }
}

const Tripwire = struct {
    calls: u32 = 0,
    fn frameFn(context: *anyopaque, _: u64, _: frame_source.Shape) void {
        const self: *Tripwire = @ptrCast(@alignCast(context));
        self.calls += 1;
    }
    fn fillFn(context: *anyopaque, _: u32, _: u32, out: []u8) void {
        const self: *Tripwire = @ptrCast(@alignCast(context));
        self.calls += 1;
        @memset(out, 0xEE);
    }
    fn closeFn(context: *anyopaque) void {
        _ = context;
    }
    const vtable = frame_source.FrameSource.VTable{ .frame = frameFn, .fill = fillFn, .close = closeFn };
};

const Bench = struct {
    store: *Store,
    unit: ceu.Ceu,

    fn open(source: frame_source.FrameSource) !Bench {
        const store = try gpa.create(Store);
        errdefer gpa.destroy(store);
        store.* = try Store.init(null);
        var unit = ceu.Ceu.init();
        unit.memory = Guest{ .store = store };
        unit.source = source;
        return .{ .store = store, .unit = unit };
    }

    fn close(self: *Bench) void {
        self.unit.source.close();
        self.store.deinit();
        gpa.destroy(self.store);
    }

    fn capture(self: *Bench) void {
        self.unit.write(at(ceu.off.capwr), 4, width | lines << ceu.field.vertical_shift);
        self.unit.write(at(ceu.off.cdwdr), 4, width);
        self.unit.write(at(ceu.off.cdayr), 4, frame_base);
        self.unit.write(at(ceu.off.capsr), 4, ceu.field.capture_enable);
    }

    fn frame(self: *Bench, out: []u8) !void {
        try (Guest{ .store = self.store }).read(frame_base, out);
    }
};

test "frames streamed through a FIFO are recorded and replay offline" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const path = try std.fmt.allocPrintSentinel(gpa, "{s}/camera.fifo", .{root}, 0);
    defer gpa.free(path);
    const made = std.os.linux.mknod(path.ptr, std.os.linux.S.IFIFO | 0o600, 0);
    if (std.os.linux.errno(made) != .SUCCESS) return error.SkipZigTest;

    const h = try fixture.MockHarness.init(gpa);
    defer h.deinit();
    var history = try ra8.session.history.History.init(gpa, undefined, 4);
    defer history.deinit();
    history.attachRecorder(&h.recorder);
    h.session.history = &history;
    h.recorder.observe(0);
    var rgb565: u8 = 0x6F;

    // Live: the reader opens the FIFO the way --camera-source does, then a
    // writer streams frames into it between captures.
    const spec = try std.fmt.allocPrint(gpa, "{s},{d}x{d},rgb24", .{ path, pipe_w, pipe_h });
    defer gpa.free(spec);
    const input = try pipe.Pipe.load(gpa, std.testing.io, spec);
    const inner = try hosted.Hosted(pipe.Pipe).open(gpa, input, &rgb565, "pipe", spec);
    var live = try Bench.open(try recorded_camera.wrap(gpa, &h.session, inner, &rgb565));
    var live_open = true;
    defer if (live_open) live.close();

    const z = try std.posix.toPosixPath(path);
    const rc = std.posix.system.open(&z, .{ .ACCMODE = .WRONLY, .NONBLOCK = true }, @as(c_uint, 0));
    if (std.posix.errno(rc) != .SUCCESS) return error.SkipZigTest;
    const writer: std.posix.fd_t = @intCast(rc);
    defer _ = std.c.close(writer);

    var sent: [pipe_w * pipe_h * 3]u8 = undefined;
    var expect: [2][frame_len]u8 = undefined;
    for (0..2) |n| {
        picture(@intCast(40 + n * 90), &sent);
        try writeAll(writer, &sent);
        h.grid_state.at.r = @intCast(n + 1);
        live.capture();
        try live.frame(&expect[n]);
    }
    const port = recorded_camera.from(live.unit.source).?;
    try std.testing.expectEqual(@as(?anyerror, null), port.failed);
    try std.testing.expect(!std.mem.eql(u8, &expect[0], &expect[1]));
    try std.testing.expect(!std.mem.allEqual(u8, &expect[1], 0));
    try h.recorder.commit(1);
    const log = h.mock_storage.bytes.items;

    // Offline: the reader and writer are closed and the FIFO removed.
    live.close();
    live_open = false;
    try temp.dir.deleteFile(std.testing.io, "camera.fifo");

    for (0..2) |_| {
        h.grid_state.at.r = 0;
        try feeder.loadSessionInterventions(&h.session, log, .at);
        defer feeder.release(&h.session);
        var tripwire: Tripwire = .{};
        const dead: frame_source.FrameSource = .{ .context = &tripwire, .vtable = &Tripwire.vtable };
        var replay = try Bench.open(try recorded_camera.wrap(gpa, &h.session, dead, &rgb565));
        defer replay.close();
        h.session.setReplaying(true);
        defer h.session.setReplaying(false);
        for (0..2) |n| {
            h.grid_state.at.r = @intCast(n + 1);
            replay.capture();
            var got: [frame_len]u8 = undefined;
            try replay.frame(&got);
            try std.testing.expectEqualSlices(u8, &expect[n], &got);
        }
        try std.testing.expectEqual(@as(u32, 0), tripwire.calls);
        try std.testing.expectEqual(@as(?anyerror, null), recorded_camera.from(replay.unit.source).?.failed);
    }
}
