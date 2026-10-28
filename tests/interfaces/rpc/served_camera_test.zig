//! Tests for src/interfaces/rpc/served_camera.zig (row 24): a served session
//! that keeps a history puts the recorded camera port around whatever
//! source it has, so a capture the CEU makes is recorded and a replay of
//! that position serves the recorded bytes without touching the host source.
const std = @import("std");
const ra8 = @import("ra8");

const setup = ra8.rpc.served_setup;
const camera = ra8.rpc.session.camera;
const ceu = ra8.chip.periph.ceu;
const frame_source = ra8.chip.periph.frame_source;
const recorded_camera = ra8.session.board.recorded_camera;
const feeder = ra8.session.history_replay_feeder;

const image = "tests/fixtures/dfu/dfu_bootloader.elf";
const frame_base: u32 = ra8.chip.core.memmap.sdram_end - 0x1000;
const width: u32 = 64;
const lines: u32 = 16;

/// A host source the replay must never call.
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

fn at(offset: u32) u32 {
    return ceu.win_base + offset;
}

fn capture(unit: *ceu.Ceu) void {
    unit.write(at(ceu.off.capwr), 4, width | lines << ceu.field.vertical_shift);
    unit.write(at(ceu.off.cdwdr), 4, width);
    unit.write(at(ceu.off.cdayr), 4, frame_base);
    unit.write(at(ceu.off.capsr), 4, ceu.field.capture_enable);
}

fn buffer(unit: *ceu.Ceu, out: []u8) !void {
    try unit.memory.?.read(frame_base, out);
}

test "a session without a history leaves the camera source bare" {
    var opened: setup.Served = undefined;
    try opened.open(std.testing.allocator, std.testing.io, image, null, null);
    defer opened.deinit();
    try std.testing.expect(recorded_camera.from(opened.owner.board().capture.source) == null);
}

test "a served history records the gradient and a picture, and replays the capture offline" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "still.ppm", .data = "P6\n2 1\n255\n" ++ "\x10\x20\x30\x40\x50\x60" });
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const spec = try std.fmt.allocPrint(gpa, "image:{s}/still.ppm", .{root});
    defer gpa.free(spec);

    var served: setup.Served = undefined;
    try served.open(gpa, std.testing.io, image, null, .{});
    defer served.deinit();
    const session = served.owner.session();
    const unit = &served.owner.board().capture;

    // The default gradient is wrapped, and so is a source set over the wire.
    try std.testing.expect(recorded_camera.from(unit.source) != null);
    const gradient_label = unit.source.label;
    const taken = camera.setCameraSource(&served.context, .{ .text = spec });
    try std.testing.expectEqual(@as(u8, 1), taken.ok.accepted);
    const port = recorded_camera.from(unit.source).?;
    try std.testing.expectEqualStrings("still image", unit.source.label);
    try std.testing.expect(!std.mem.eql(u8, gradient_label, unit.source.label));

    // A capture at the head of the run is recorded.
    _ = try session.run(.cpu0, .run);
    capture(unit);
    try std.testing.expectEqual(@as(?anyerror, null), port.failed);
    try std.testing.expectEqual(@as(u32, 1), unit.frames);
    var live: [width * lines]u8 = undefined;
    try buffer(unit, &live);
    try std.testing.expect(!std.mem.allEqual(u8, &live, 0));

    // Replayed at the same position, the bytes come from the history and
    // the host source behind the port is never called.
    const bridge = served.owner.transport().history.?;
    try feeder.loadSessionInterventions(session, try bridge.logBytes.?(bridge.context), .at);
    defer feeder.release(session);
    try std.testing.expectEqual(@as(usize, 1), session.replay_feeder.?.frames.items.len);
    var tripwire: Tripwire = .{};
    port.inner.close();
    port.inner = .{ .context = &tripwire, .vtable = &Tripwire.vtable };
    const zeros = std.mem.zeroes([width * lines]u8);
    try unit.memory.?.write(frame_base, &zeros);
    session.setReplaying(true);
    defer session.setReplaying(false);
    capture(unit);
    var replayed: [width * lines]u8 = undefined;
    try buffer(unit, &replayed);
    try std.testing.expectEqual(@as(?anyerror, null), port.failed);
    try std.testing.expectEqual(@as(u64, 1), port.replayed);
    try std.testing.expectEqual(@as(u32, 0), tripwire.calls);
    try std.testing.expectEqualSlices(u8, &live, &replayed);
}

const FakeWall = struct {
    now_ns: u64 = 0,
    fn now(context: *anyopaque) u64 {
        const self: *FakeWall = @ptrCast(@alignCast(context));
        self.now_ns += 1_000_000;
        return self.now_ns;
    }
    fn wall(self: *FakeWall) ra8.session.transport.Wall {
        return .{ .context = self, .nowFn = now };
    }
};

test "a replayed capture with nothing recorded stops the run and the stop reaches the transport, RPC and report" {
    const gpa = std.testing.allocator;
    var served: setup.Served = undefined;
    try served.open(gpa, std.testing.io, image, null, .{});
    defer served.deinit();
    const session = served.owner.session();
    const unit = &served.owner.board().capture;
    const port = recorded_camera.from(unit.source).?;
    _ = try session.run(.cpu0, .run);

    // A replay of a capture the history has no frame for.
    session.setReplaying(true);
    defer session.setReplaying(false);
    capture(unit);
    try std.testing.expectEqual(@as(?anyerror, recorded_camera.Error.UnrecordedCapture), port.failed);

    // The transport's next step ends on the failure, not on a finished step.
    const plane = served.owner.transport();
    var wall: FakeWall = .{};
    const ticket = try plane.command(.{ .step = .{ .core = .cpu0, .count = 1, .dir = .fwd } });
    const ended = try plane.finish(ticket, wall.wall(), null);
    const failure = ended.stop.replay_failed;
    try std.testing.expectEqual(ra8.session.stop_machine.ReplaySource.camera, failure.source);
    try std.testing.expectEqual(@as(anyerror, recorded_camera.Error.UnrecordedCapture), failure.err);

    // RPC: its own stop reason, with the source as the detail.
    const wire = ra8.rpc.session.handlers.stopped(session, .cpu0, ended);
    try std.testing.expectEqual(ra8.rpc.session.rpc.StopReason.replay_failed, wire.reason);
    try std.testing.expectEqual(@as(u32, 1), wire.detail);

    // CLI: the stop line names the source and the error.
    var line: [128]u8 = undefined;
    var out: std.Io.Writer = .fixed(&line);
    try ra8.session.step_hook.report.prefix(&out, ended.stop, false);
    try std.testing.expectEqualStrings("Replay failed: camera source, UnrecordedCapture, ", out.buffered());

    // Reported once: the failure is not left to stop the next slice too.
    try std.testing.expect(session.replay_failure == null);
}
