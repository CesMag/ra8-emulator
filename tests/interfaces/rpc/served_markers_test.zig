//! Late-armed markers through the served setup: arm one after recording,
//! seek to its Nth arrival, close, reopen the kept history and seek again
//! from the cache with the same position and without a second replay.
const std = @import("std");
const ra8 = @import("ra8");

const setup = ra8.rpc.served_setup;
const nav_marker = ra8.rpc.session.nav_marker;
const transport = ra8.session.transport;
const history = ra8.host.history;
const rig = @import("regression_rig.zig");

const image = "tests/fixtures/dfu/dfu_bootloader.elf";
const steps = 300;

const FakeWall = struct {
    now_ns: u64 = 0,
    fn now(context: *anyopaque) u64 {
        const self: *FakeWall = @ptrCast(@alignCast(context));
        self.now_ns += 1_000_000;
        return self.now_ns;
    }
    fn wall(self: *FakeWall) transport.Wall {
        return .{ .context = self, .nowFn = now };
    }
};

/// Steps the machine and answers an address its program counter came back to.
fn loopAddress(served: *setup.Served) !u32 {
    const session = served.owner.session();
    var seen: [steps]u32 = undefined;
    for (&seen) |*slot| {
        _ = try session.run(.cpu0, .step);
        slot.* = (try session.register(.cpu0, .pc)) & ~@as(u32, 1);
    }
    for (seen[0 .. steps - 1], 0..) |pc, at| {
        for (seen[at + 1 ..]) |later| if (later == pc) return pc;
    }
    return error.NoLoopInTrace;
}

fn arm(served: *setup.Served, place: []const u8) !ra8.rpc.session.rpc.NavQueryResult {
    return switch (nav_marker.markerSet(&served.context, .{ .name = "loop", .place = place })) {
        .ok => |reply| reply,
        .err => error.ArmRefused,
    };
}

fn seekMarker(served: *setup.Served, text: []const u8) !ra8.session.history_position.Position {
    const t = served.owner.transport();
    var wall = FakeWall{};
    const ticket = try t.command(.{ .seek = .{ .target = text } });
    _ = try t.finish(ticket, wall.wall(), null);
    return served.owner.session().currentPosition();
}

test "a late marker is indexed by replay, cached, and served again after a reopen" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);

    var id: history.name.Id = undefined;
    var place_buf: [16]u8 = undefined;
    var arrivals: u64 = 0;
    var landed: ra8.session.history_position.Position = undefined;
    {
        var served: setup.Served = undefined;
        try served.open(gpa, std.testing.io, image, rig.small_profile, .{ .root = root, .checkpoint_every = 16, .kept = true });
        defer served.deinit();
        id = served.history.?.session.id;
        const address = try loopAddress(&served);
        const place = try std.fmt.bufPrint(&place_buf, "0x{x}", .{address});
        const session = served.owner.session();
        const origin = session.currentPosition();

        const armed = try arm(&served, place);
        try std.testing.expect(armed.found == 1);
        try std.testing.expect(armed.count >= 2);
        arrivals = armed.count;
        // The replay put the machine back where it stood.
        try std.testing.expectEqual(std.math.Order.eq, try session.comparePositions(origin, session.currentPosition()));

        landed = try seekMarker(&served, "marker loop 2");
        try std.testing.expectEqual(@as(u32, address), (try session.register(.cpu0, .pc)) & ~@as(u32, 1));
        try std.testing.expectEqual(@as(usize, @intCast(arrivals)), served.nav.?.markerArrivalCount("loop"));
        try std.testing.expectEqual(landed, served.nav.?.getMarkerArrival("loop", 2).?);
    }

    var again: setup.Served = undefined;
    try again.open(gpa, std.testing.io, image, rig.small_profile, .{ .root = root, .checkpoint_every = 16, .reopen = &id });
    defer again.deinit();
    // The cache is back before anything runs.
    try std.testing.expectEqual(@as(usize, @intCast(arrivals)), again.nav.?.markerArrivalCount("loop"));
    const epoch = again.owner.transport().epoch;
    const rearmed = try arm(&again, "0x0");
    try std.testing.expectEqual(arrivals, rearmed.count);
    // No replay ran: the transport never restarted a job for it.
    try std.testing.expectEqual(epoch, again.owner.transport().epoch);
    const second = try seekMarker(&again, "marker loop 2");
    try std.testing.expectEqual(landed, second);
}

test "a marker indexed over a shorter log is armed again once the history grew" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);

    var served: setup.Served = undefined;
    try served.open(gpa, std.testing.io, image, rig.small_profile, .{ .root = root, .checkpoint_every = 16, .kept = true });
    defer served.deinit();
    var place_buf: [16]u8 = undefined;
    const address = try loopAddress(&served);
    const place = try std.fmt.bufPrint(&place_buf, "0x{x}", .{address});
    const nav = served.nav.?;

    _ = try arm(&served, place);
    const held = nav.markerArrivalCount("loop");
    try std.testing.expect(held >= 2);
    const armed_end = nav_marker.historyEnd(served.owner.transport());
    try std.testing.expect(armed_end > 0);

    // Current while the log stands where it was.
    _ = try arm(&served, place);
    try std.testing.expectEqual(held, nav.markerArrivalCount("loop"));

    // A log that grew past the end the arrivals were indexed over: the
    // arrivals no longer answer and the next arm replays again.
    for (nav.marker_arrivals.items) |*m| {
        if (m.end != null) m.end = armed_end -| 1;
    }
    const again = try arm(&served, place);
    try std.testing.expectEqual(held, again.count);
    for (nav.marker_arrivals.items) |m| {
        if (std.mem.eql(u8, m.name, "loop")) try std.testing.expectEqual(armed_end, m.end.?);
    }
    try std.testing.expectEqual(@as(usize, 1), nav.markerArrivalCount("boot"));
}

test "the DFU marker prefix preserves the default board's execution with smaller external memory" {
    const gpa = std.testing.allocator;
    var reference = try ra8.session.harness.open(gpa, std.testing.io, .{ .elf_path = image, .history_frames = 2 });
    defer reference.deinit();
    var reduced = try ra8.session.harness.open(gpa, std.testing.io, .{ .elf_path = image, .board_profile = rig.small_profile, .history_frames = 2 });
    defer reduced.deinit();
    // The equivalence guard compares guest execution, not legacy capture cost.
    // The two marker scenarios above still capture all 300 actual stops.
    reference.session().history = null;
    reduced.session().history = null;
    const store = &reduced.state.cpu0.store.?;
    const loaded = try ra8.board.image.load.read(reduced.state.image);
    try std.testing.expect(loaded.count > 0);
    for (loaded.maps.items()) |range| try std.testing.expect(store.span(range.base, range.size()) != null);
    for (loaded.segments[0..loaded.count]) |segment| {
        try std.testing.expectEqualSlices(u8, segment.bytes, store.span(segment.paddr, segment.bytes.len).?);
    }
    for (0..steps) |_| {
        try std.testing.expectEqual(ra8.session.api.Ended{ .stop = .stepped }, try reference.session().run(.cpu0, .step));
        try std.testing.expectEqual(ra8.session.api.Ended{ .stop = .stepped }, try reduced.session().run(.cpu0, .step));
        try expectCpuTrace(&reference, &reduced);
        try std.testing.expectEqualDeep(reference.state.edge.saved, reduced.state.edge.saved);
        try std.testing.expectEqual(reference.board().time.base.now(), reduced.board().time.base.now());
        try std.testing.expectEqual(try reference.session().now(), try reduced.session().now());
    }
    const memmap = ra8.chip.core.memmap;
    const original = &reference.state.cpu0.store.?;
    for (memmap.ram) |entry| {
        if (entry.base == memmap.sdram_base or entry.base == memmap.ns_sdram_base) continue;
        try std.testing.expectEqualSlices(u8, original.region(entry.base).?, store.region(entry.base).?);
    }
    for (original.extra.windows) |held| if (held) |window| {
        try std.testing.expectEqualSlices(u8, window.bytes, store.extra.span(window.base, window.bytes.len).?);
    };
    for ([_]u32{ memmap.scb.cfsr, memmap.scb.hfsr }) |address| {
        try std.testing.expectEqual(@as(u32, 0), try reference.guest().readWord(address));
        try std.testing.expectEqual(@as(u32, 0), try reduced.guest().readWord(address));
    }
    std.debug.print("DFU prefix: steps={d} retired={d} slots={d} pc=0x{x} CFSR=0 HFSR=0\n", .{ steps, reduced.primaryCpu().retired, reduced.primaryCpu().slots, reduced.primaryCpu().regs.pc });
}

fn expectCpuTrace(reference: *ra8.session.harness.Harness, reduced: *ra8.session.harness.Harness) !void {
    const a = reference.primaryCpu();
    const b = reduced.primaryCpu();
    try std.testing.expectEqualDeep(a.regs, b.regs);
    try std.testing.expectEqualDeep(a.banked, b.banked);
    try std.testing.expectEqualDeep(a.fp, b.fp);
    try std.testing.expectEqualDeep(a.active, b.active);
    try std.testing.expectEqualDeep(a.waiting, b.waiting);
    try std.testing.expectEqual(a.event, b.event);
    try std.testing.expectEqual(a.retired, b.retired);
    try std.testing.expectEqual(a.slots, b.slots);
    try std.testing.expectEqual(a.sync_entries, b.sync_entries);
}
