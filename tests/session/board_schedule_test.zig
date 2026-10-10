//! RA8EMU-207 slice 2: a fault schedule applied on a Zig-core run lands
//! each event at its exact virtual time. tests/fixtures/plug/gauge_poll.elf
//! polls the MAX17048 at 0x36 forever; the schedule unplugs it, plugs it
//! back, faults it and clears the fault, and the test reads the time each
//! event was applied at and the session's event stream.
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
const session_faults = ra8.session.board_faults;
const session_schedule = ra8.session.board_schedule;
const fault_schedule = ra8.components.model.fault_schedule;

const image_bytes = @embedFile("../fixtures/plug/gauge_poll.elf");
const counts_at: u32 = 0x2200_0100;

// Odd times on purpose, so none lands on a natural stretch edge.
const text =
    \\0s        plug   i2c:riic@0x36 max17048
    \\123457ns  unplug i2c:riic@0x36
    \\250us     plug   i2c:riic@0x36 max17048
    \\250us     fault  i2c:riic@0x36 disconnected
    \\377777ns  clear  i2c:riic@0x36
;

test "a fault schedule applies every event at its exact virtual time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag = fault_schedule.Diagnostic{};
    const plan = try fault_schedule.parse(std.testing.allocator, text, &diag);
    defer plan.deinit(std.testing.allocator);

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
    var faults = session_faults.Faults.init(&board, arena.allocator());
    var session: api.Session = .{ .live = undefined };
    session.attachPlugs(plugs.hook());
    session.attachFaults(&faults);
    session.attachTimeBase(&board.time.base);
    const subscription = try session.subscribe();

    var timebase: ra8.chip.periph.clocks.Clocks = .{ .per_chunk = 5_000 };
    var clock: zig_run.Clock = .{ .io = std.testing.io, .memory = core, .board = &board, .timebase = &timebase };
    var applied: [5]u64 = .{ 0, 0, 0, 0, 0 };
    var applier: session_schedule.Applier = .{
        .events = plan.events,
        .session = &session,
        .clock = &board.time.base,
        .inner = clock.boundary(),
        .applied_ns = &applied,
    };
    try applier.start();
    try std.testing.expectEqual(@as(usize, 1), applier.next);

    var ran: u64 = 0;
    var output: [256]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&output);
    const vector_base = image.vectorBase() orelse return error.MissingVectorTable;
    _ = try boot.start(&stream, .zig, core, &board.bus, vector_base, 500_000, &ran, .{
        .boundary = applier.boundary(),
        .partitions = &board.partitions,
        .idau = &board.idau,
        .regions = &board.regions,
        .regions_ns = &board.regions_ns,
        .clears = &board.clears,
    });
    try std.testing.expect(applier.finished());
    for (plan.events, applied) |event, at| try std.testing.expectEqual(event.at_ns, at);

    const want = [_]api.Event.Kind{ .plugged, .unplugged, .plugged, .fault_set, .fault_cleared };
    var events: [want.len]api.Event = undefined;
    const got = session.pollEvents(subscription, &events).?;
    try std.testing.expectEqual(want.len, got.count);
    for (events, want, plan.events) |event, kind, scheduled| {
        try std.testing.expectEqual(kind, event.kind);
        try std.testing.expectEqual(scheduled.at_ns, event.virtual_ns);
    }
    // The firmware lived through it: it saw the gauge go and come back.
    try std.testing.expect(try core.readWord(counts_at + 4) > 0);
    try std.testing.expect(try core.readWord(counts_at + 8) > 0);
}

const ScaledBoundary = struct {
    fn width(_: *anyopaque) u32 {
        return 500_000;
    }

    fn close(_: *anyopaque, _: u32) anyerror!void {}

    fn cycles(_: *anyopaque, count: u64) u64 {
        return count * 2;
    }
};

test "a fault schedule converts its cycle edge to an instruction width" {
    var diag = fault_schedule.Diagnostic{};
    const plan = try fault_schedule.parse(std.testing.allocator, text, &diag);
    defer plan.deinit(std.testing.allocator);
    var marker: u8 = 0;
    var session: api.Session = .{ .live = undefined };
    var clock: ra8.chip.periph.clocks.timebase.TimeBase = .{};
    var applier: session_schedule.Applier = .{
        .events = plan.events,
        .session = &session,
        .clock = &clock,
        .inner = .{ .context = &marker, .widthFn = ScaledBoundary.width, .closeFn = ScaledBoundary.close, .cyclesFn = ScaledBoundary.cycles },
        .next = 1,
    };
    const boundary = applier.boundary();
    try std.testing.expectEqual(@as(u32, 246_914), boundary.widthFn(boundary.context));
    try std.testing.expectEqual(@as(u64, 10), boundary.cyclesFn.?(boundary.context, 5));
}
