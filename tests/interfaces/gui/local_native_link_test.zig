//! Tests for src/interfaces/gui/local_native_link.zig (slice 15): the
//! shell's native link queues typed requests for the session's thread,
//! which dispatches them to the handlers and queues the arrivals the
//! window takes. The answers are the ones the wire link gives, with no
//! bytes between the two sides.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");

const local_native_link = gui_app.local_native_link;
const session_link = gui_app.session_link;
const served_setup = ra8.rpc.served_setup;
const proto = ra8.rpc.session.rpc;

const image = "tests/fixtures/fpu/fp_basic.elf";

fn opened(gpa: std.mem.Allocator) !served_setup.Served {
    var setup: served_setup.Served = undefined;
    try setup.open(gpa, std.testing.io, image, null, null);
    return setup;
}

test "a typed request answers through the native link" {
    const gpa = std.testing.allocator;
    var setup = try opened(gpa);
    defer setup.deinit();
    var host = gui_app.wall_clock.Host.init(std.testing.io);
    const clock = host.clock();
    var native = local_native_link.Native.init(std.testing.io, gpa, clock, &setup.context);
    defer native.deinit();
    var link: session_link.Link = undefined;
    link.openNative(&native);

    const id = try link.send(proto.ReadRegister, .read_register, .{ .core = .cpu0, .register = .pc });
    _ = try native.serve();
    const arrival = link.pump().?;
    try std.testing.expectEqualStrings("response", @tagName(arrival));
    try std.testing.expectEqual(id, arrival.response.id);
    const reply = try proto.decode(proto.U32, arrival.response.result.ok);
    try std.testing.expect(reply.value != 0);
    try std.testing.expect((link.pump()) == null);
}

test "a full mailbox refuses more sends until the session drains it" {
    const gpa = std.testing.allocator;
    var setup = try opened(gpa);
    defer setup.deinit();
    var host = gui_app.wall_clock.Host.init(std.testing.io);
    const clock = host.clock();
    var native = local_native_link.Native.init(std.testing.io, gpa, clock, &setup.context);
    defer native.deinit();
    var link: session_link.Link = undefined;
    link.openNative(&native);

    var sent: usize = 0;
    while (sent < local_native_link.max_requests) : (sent += 1) {
        _ = try link.send(proto.Now, .now, .{ .core = .cpu0 });
    }
    try std.testing.expectError(error.TableFull, link.send(proto.Now, .now, .{ .core = .cpu0 }));
    _ = try native.serve();
    var taken: usize = 0;
    while (link.pump()) |arrival| {
        try std.testing.expectEqualStrings("response", @tagName(arrival));
        taken += 1;
        if (taken == local_native_link.max_requests) break;
    }
    try std.testing.expectEqual(local_native_link.max_requests, taken);
    _ = try link.send(proto.Now, .now, .{ .core = .cpu0 });
}

test "the session's stop event reaches the window's pump" {
    const gpa = std.testing.allocator;
    var setup = try opened(gpa);
    defer setup.deinit();
    var host = gui_app.wall_clock.Host.init(std.testing.io);
    const clock = host.clock();
    var native = local_native_link.Native.init(std.testing.io, gpa, clock, &setup.context);
    defer native.deinit();
    var link: session_link.Link = undefined;
    link.openNative(&native);

    _ = try link.send(proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .stop });
    _ = try native.serve();
    const ack = link.pump().?;
    try std.testing.expectEqualStrings("response", @tagName(ack));

    _ = try link.send(proto.CoreOnly, .step, .{ .core = .cpu0 });
    var stop_seen = false;
    while (!stop_seen) {
        _ = try native.serve();
        const arrival = link.pump() orelse break;
        if (arrival == .event and arrival.event.topic == @backingInt(proto.Topic.stop)) {
            const stopped = try proto.decode(proto.Stopped, arrival.event.payload);
            try std.testing.expectEqual(proto.Core.cpu0, stopped.core);
            stop_seen = true;
        }
    }
    try std.testing.expect(stop_seen);
}

test "device metrics cache is demand driven and does not block on a busy session" {
    const gpa = std.testing.allocator;
    var setup = try opened(gpa);
    defer setup.deinit();
    var host = gui_app.wall_clock.Host.init(std.testing.io);
    var native = local_native_link.Native.init(std.testing.io, gpa, host.clock(), &setup.context);
    defer native.deinit();
    const Probe = struct {
        calls: usize = 0,
        fn read(context: *anyopaque, core: u1) ra8.session.device_metrics.Snapshot {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            return .{ .attached = core == 0, .active = 123 };
        }
    };
    var probe: Probe = .{};
    setup.context.session.metrics = .{ .context = &probe, .readFn = Probe.read };
    _ = try native.serve();
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    try std.testing.expect(native.metrics() == null);
    _ = try native.serve();
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
    const cached = native.metrics().?;
    try std.testing.expectEqual(@as(u64, 123), cached[0].active);
    try std.testing.expect(native.metrics() == null);
    native.mutex.lockUncancelable(std.testing.io);
    const blocked = native.metrics();
    native.mutex.unlock(std.testing.io);
    try std.testing.expect(blocked == null);
}

test "recording GUI metrics account independently for running M85 and M33" {
    var local: gui_app.local_session.LocalSession = undefined;
    try local.openRecordingPair(std.testing.allocator, std.testing.io, "tests/fixtures/trustzone/cpu1_pingpong_ipc.elf", null, null, &.{}, "tests/fixtures/trustzone/cpu1_pingpong_ipc_cpu1.elf");
    defer local.deinit();
    var clock = gui_app.wall_clock.Host.init(std.testing.io);
    var native = local_native_link.Native.init(std.testing.io, std.testing.allocator, clock.clock(), &local.setup.context);
    defer native.deinit();
    _ = native.metrics();
    _ = try native.serve();
    const before = native.metrics().?;
    try std.testing.expect(before[0].attached and before[1].attached);
    try local.setup.owner.session().setRunBudget(.cpu0, 100_000);
    _ = try local.setup.owner.session().run(.cpu0, .cont);
    _ = try native.serve();
    const after = native.metrics().?;
    try std.testing.expect(after[0].active > before[0].active);
    try std.testing.expect(after[1].active > before[1].active);
    try std.testing.expectEqual(after[0].msp.pointer, local.setup.owner.primaryCpu().regs.msp);
    try std.testing.expectEqual(after[1].msp.pointer, local.setup.second.?.cpu().regs.msp);
    try std.testing.expectEqual(after[0].active, local.setup.owner.primaryCpu().slots);
    try std.testing.expectEqual(after[1].active, local.setup.second.?.cpu().slots);
    try std.testing.expectEqual(after[0].sram.pages, after[1].sram.pages);
    try std.testing.expectEqual(after[0].sram.capacity, after[1].sram.capacity);
    try std.testing.expect(after[0].sram.pages > 0);
    var window: ra8.session.device_metrics.Window = .{};
    window.sample(&after[1]);
    const chip = ra8.chip.core.cpu;
    const Quiet = struct {
        fn winner(_: *anyopaque, _: chip.bus.Bus) chip.bus.Error!?chip.exception.active.Entry {
            return null;
        }
        fn event(_: *anyopaque, _: chip.bus.Bus, _: u9) chip.bus.Error!void {}
    };
    var context: u8 = 0;
    const second = local.setup.second.?.cpu();
    second.source = .{ .ctx = &context, .vtable = &.{ .winner = Quiet.winner, .taken = Quiet.event, .returned = Quiet.event } };
    second.waiting = .interrupt;
    _ = try local.setup.owner.session().run(.cpu0, .cont);
    _ = try native.serve();
    const sleeping = native.metrics().?;
    try std.testing.expectEqual(after[1].active, sleeping[1].active);
    try std.testing.expect(sleeping[1].idle > after[1].idle);
    window.sample(&sleeping[1]);
    try std.testing.expectEqual(@as(u8, 0), window.percent);
    try std.testing.expect(!window.pinned);
    std.debug.print("dual core metrics: M85 active={d} idle={d}; M33 active={d} idle={d}; shared SRAM pages={d}\n", .{ after[0].active, after[0].idle, after[1].active, after[1].idle, after[0].sram.pages });
}
