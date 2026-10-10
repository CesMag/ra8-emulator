//! RA8EMU-212 done condition: firmware polling the MAX17048 gauge sees it
//! vanish and come back mid-run. tests/fixtures/plug/gauge_poll.elf probes
//! 0x36 on the sensor line forever and counts acks and nacks in SRAM. The
//! run is cut at stretch boundaries: the gauge is unplugged through the
//! session partway in and plugged back later, and the firmware's counts
//! and the session's event stream are read at each step.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const store_board = @import("../interfaces/cli/store_board.zig");

const api = ra8.session.session_api;
const boot = ra8.chip.core.cpu.boot;
const elf = ra8.board.image.elf;
const loader = ra8.chip.core.cpu.memory.load;
const zig_run = cli_app.zig_run;
const session_plug = ra8.session.board_plug;
const Endpoint = ra8.components.model.endpoint.Endpoint;

const image_bytes = @embedFile("../fixtures/plug/gauge_poll.elf");
const gauge_at: Endpoint = .{ .i2c = .{ .line = .riic, .address = 0x36 } };
const counts_at: u32 = 0x2200_0100;
/// Instructions between the cuts: enough for hundreds of probes each.
const phase: u64 = 200_000;

const Counts = struct { polls: u32, acks: u32, nacks: u32, changes: u32 };

/// Wraps the run's own boundary: at each cut it reads the firmware's
/// counts, then unplugs or replugs the gauge through the session.
const Cuts = struct {
    inner: boot.Boundary,
    session: *api.Session,
    memory: store_board.Guest,
    ran: u64 = 0,
    taken: [3]Counts = undefined,
    step: usize = 0,
    failed: ?anyerror = null,

    fn boundary(self: *Cuts) boot.Boundary {
        return .{ .context = self, .widthFn = width, .closeFn = close, .reboot = self.inner.reboot, .doneFn = done };
    }

    fn width(context: *anyopaque) u32 {
        const self: *Cuts = @ptrCast(@alignCast(context));
        return self.inner.widthFn(self.inner.context);
    }

    fn close(context: *anyopaque, instructions: u32) anyerror!void {
        const self: *Cuts = @ptrCast(@alignCast(context));
        try self.inner.closeFn(self.inner.context, instructions);
        self.ran += instructions;
        if (self.step >= self.taken.len or self.ran < phase * (self.step + 1)) return;
        self.taken[self.step] = try self.read();
        switch (self.step) {
            0 => try self.session.unplug(.cpu0, gauge_at),
            1 => try self.session.plug(.cpu0, gauge_at, "max17048"),
            else => {},
        }
        self.step += 1;
    }

    fn done(context: *anyopaque) bool {
        const self: *Cuts = @ptrCast(@alignCast(context));
        return self.step >= self.taken.len;
    }

    fn read(self: *Cuts) !Counts {
        return .{
            .polls = try self.memory.readWord(counts_at),
            .acks = try self.memory.readWord(counts_at + 4),
            .nacks = try self.memory.readWord(counts_at + 8),
            .changes = try self.memory.readWord(counts_at + 12),
        };
    }
};

test "firmware polling the gauge sees it unplugged and plugged back mid-run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const image = try elf.Image.init(image_bytes);
    var store = try store_board.Store.init(null);
    defer store.deinit();
    const core: store_board.Guest = .{ .store = &store };
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try store_board.attach(&board, core);
    const loaded = try ra8.board.image.load.read(image);
    _ = try loader.image(core, loaded.image());

    var plugs = session_plug.Plugs.init(&board, arena.allocator());
    var session: api.Session = .{ .live = undefined };
    session.attachPlugs(plugs.hook());
    const subscription = try session.subscribe();
    try session.plug(.cpu0, gauge_at, "max17048");

    var timebase: ra8.chip.periph.clocks.Clocks = .{ .per_chunk = 5_000 };
    var clock: zig_run.Clock = .{ .io = std.testing.io, .memory = core, .board = &board, .timebase = &timebase };
    var cuts: Cuts = .{ .inner = clock.boundary(), .session = &session, .memory = core };
    var ran: u64 = 0;
    var output: [256]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&output);
    const vector_base = image.vectorBase() orelse return error.MissingVectorTable;
    _ = try boot.start(&stream, .zig, core, &board.bus, vector_base, phase * 4, &ran, .{
        .boundary = cuts.boundary(),
        .partitions = &board.partitions,
        .idau = &board.idau,
        .regions = &board.regions,
        .regions_ns = &board.regions_ns,
        .clears = &board.clears,
    });
    try std.testing.expectEqual(@as(usize, 3), cuts.step);
    const before, const out, const back = cuts.taken;
    // Plugged: every probe answered.
    try std.testing.expect(before.acks > 0);
    try std.testing.expectEqual(@as(u32, 0), before.nacks);
    // Unplugged: the firmware sees nacks and no new acks, beyond a probe
    // already past its address phase at the cut.
    try std.testing.expect(out.nacks > 0);
    try std.testing.expect(out.acks <= before.acks + 1);
    // Plugged back: acks climb again and the nacks stop.
    try std.testing.expect(back.acks > out.acks + 1);
    try std.testing.expect(back.nacks <= out.nacks + 1);
    try std.testing.expectEqual(@as(u32, 2), back.changes);
    var events: [3]api.Event = undefined;
    const got = session.pollEvents(subscription, &events).?;
    try std.testing.expectEqual(@as(usize, 3), got.count);
    try std.testing.expectEqual(api.Event.Kind.plugged, events[0].kind);
    try std.testing.expectEqual(api.Event.Kind.unplugged, events[1].kind);
    try std.testing.expectEqual(api.Event.Kind.plugged, events[2].kind);
}
