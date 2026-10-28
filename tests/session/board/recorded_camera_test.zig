//! Covers src/session/board/recorded_camera.zig: a real CEU capture through
//! the recorded port is recorded once and replays the same bytes into guest
//! memory any number of times without the host source being read, and a
//! replayed capture nothing was recorded for is a determinism error rather
//! than a live read.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("../fork_fixture.zig");

const ceu = ra8.chip.periph.ceu;
const frame_source = ra8.chip.periph.frame_source;
const recorded_camera = ra8.session.board.recorded_camera;
const feeder = ra8.session.history_replay_feeder;
const Store = ra8.chip.core.cpu.memory.store.Store;
const Guest = ra8.chip.core.cpu.memory.guest.Guest;

const frame_base: u32 = ra8.chip.core.memmap.sdram_end - 0x1000;
const width: u32 = 64;
const lines: u32 = 40;
const frame_len: usize = width * lines;

/// A host source with a pattern that changes at every capture, counting
/// every call the CEU's path makes into it.
const Host = struct {
    captures: u32 = 0,
    calls: u32 = 0,

    fn frameFn(context: *anyopaque, _: u64, _: frame_source.Shape) void {
        const self: *Host = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.captures += 1;
    }
    fn fillFn(context: *anyopaque, row: u32, column: u32, out: []u8) void {
        const self: *Host = @ptrCast(@alignCast(context));
        self.calls += 1;
        for (out, 0..) |*byte, i| {
            const col: u32 = column + @as(u32, @intCast(i));
            byte.* = @truncate(self.captures *% 37 +% row *% 7 +% (col >> 2) *% 3);
        }
    }
    fn closeFn(context: *anyopaque) void {
        _ = context;
    }
    const vtable = frame_source.FrameSource.VTable{ .frame = frameFn, .fill = fillFn, .close = closeFn };

    fn source(self: *Host) frame_source.FrameSource {
        return .{ .context = self, .vtable = &vtable };
    }
};

fn at(offset: u32) u32 {
    return ceu.win_base + offset;
}

/// A CEU over guest memory with a recorded port around `host`.
const Bench = struct {
    store: *Store,
    unit: ceu.Ceu,

    fn open(session: *ra8.session.api.Session, host: *Host, format: *const u8) !Bench {
        const store = try std.testing.allocator.create(Store);
        errdefer std.testing.allocator.destroy(store);
        store.* = try Store.init(null);
        var unit = ceu.Ceu.init();
        unit.memory = Guest{ .store = store };
        unit.source = try recorded_camera.wrap(std.testing.allocator, session, host.source(), format);
        return .{ .store = store, .unit = unit };
    }

    fn close(self: *Bench) void {
        self.unit.source.close();
        self.store.deinit();
        std.testing.allocator.destroy(self.store);
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

test "a capture is recorded once and replays the same bytes twice without reading the host" {
    const gpa = std.testing.allocator;
    const h = try fixture.MockHarness.init(gpa);
    defer h.deinit();
    var history = try ra8.session.history.History.init(gpa, undefined, 4);
    defer history.deinit();
    history.attachRecorder(&h.recorder);
    h.session.history = &history;
    h.recorder.observe(0);
    var format: u8 = 0x30;

    // Live: two captures at two positions.
    var host: Host = .{};
    var live = try Bench.open(&h.session, &host, &format);
    defer live.close();
    var expect: [2][frame_len]u8 = undefined;
    for (0..2) |n| {
        h.grid_state.at.r = @intCast(n + 1);
        live.capture();
        try live.frame(&expect[n]);
    }
    try std.testing.expectEqual(@as(?anyerror, null), recorded_camera.from(live.unit.source).?.failed);
    try std.testing.expect(!std.mem.eql(u8, &expect[0], &expect[1]));
    try h.recorder.commit(1);
    const log = h.mock_storage.bytes.items;
    const recorded_len = log.len;

    // Replay twice from the start, with a host that must never be touched.
    for (0..2) |_| {
        h.grid_state.at.r = 0;
        try feeder.loadSessionInterventions(&h.session, log, .at);
        defer feeder.release(&h.session);
        var tripwire: Host = .{};
        var replay = try Bench.open(&h.session, &tripwire, &format);
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
        const port = recorded_camera.from(replay.unit.source).?;
        try std.testing.expectEqual(@as(u64, 2), port.replayed);
        try std.testing.expectEqual(@as(?anyerror, null), port.failed);

        // A third capture has nothing recorded: an error, not a live read.
        h.grid_state.at.r = 3;
        replay.capture();
        try std.testing.expectEqual(@as(?anyerror, recorded_camera.Error.UnrecordedCapture), port.failed);
        try std.testing.expectEqual(@as(u32, 0), tripwire.calls);
        var blank: [frame_len]u8 = undefined;
        try replay.frame(&blank);
        try std.testing.expect(std.mem.allEqual(u8, &blank, 0));
    }
    // Replaying recorded nothing new.
    try h.recorder.commit(2);
    try std.testing.expectEqual(recorded_len, h.mock_storage.bytes.items.len);
}

test "a capture with no history recorder only reads the host" {
    const gpa = std.testing.allocator;
    const h = try fixture.MockHarness.init(gpa);
    defer h.deinit();
    var format: u8 = 0x60;
    var host: Host = .{};
    var bench = try Bench.open(&h.session, &host, &format);
    defer bench.close();
    bench.capture();
    try std.testing.expectEqual(@as(u32, 1), host.captures);
    try std.testing.expectEqual(@as(usize, 0), h.mock_storage.bytes.items.len);
}
