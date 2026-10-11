//! Over-the-wire test for the session topic (RA8EMU-942): a spawned
//! `serve --stdio` session sends breakpoint_set and input_scheduled to a
//! client that subscribed the core to session, and nothing from before the
//! subscription.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const test_paths = @import("test_paths");
const proto = ra8.rpc.session.rpc;
const session_link = gui_app.session_link;
const Link = session_link.Link;
const Env = proto.Client.Env;

const elf_path = "tests/fixtures/fpu/fp_basic.elf";

const Seen = struct {
    events: [16]proto.SessionEvent = undefined,
    len: usize = 0,

    fn keep(self: *Seen, event: Env.Event) !void {
        if (event.topic != @backingInt(proto.Topic.session)) return;
        if (self.len == self.events.len) return error.TooManyEvents;
        self.events[self.len] = try proto.decode(proto.SessionEvent, event.payload);
        self.len += 1;
    }
};

fn clock() i64 {
    return std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds();
}

fn connect(link: *Link) !void {
    const deadline = clock() + 10_000;
    while (link.state == .connecting and clock() < deadline) {
        _ = link.pump();
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(link.state == .connected);
}

/// Send one request and wait for its answer, keeping session events that
/// arrive before it.
fn call(link: *Link, seen: *Seen, comptime Args: type, method: proto.Method, args: Args) !Env.Result {
    const id = try link.send(Args, method, args);
    const deadline = clock() + 10_000;
    while (clock() < deadline) {
        if (link.state != .connected) return error.LinkLost;
        const arrival = link.pump() orelse {
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
            continue;
        };
        switch (arrival) {
            .response => |response| if (response.id == id) return response.result,
            .event => |event| try seen.keep(event),
        }
    }
    return error.Timeout;
}

/// Pump for a short while so events sent after the last answer land.
fn drain(link: *Link, seen: *Seen) !void {
    const until = clock() + 200;
    while (clock() < until) {
        const arrival = link.pump() orelse {
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
            continue;
        };
        switch (arrival) {
            .response => {},
            .event => |event| try seen.keep(event),
        }
    }
}

fn ok(result: Env.Result) !void {
    try std.testing.expect(result == .ok);
}

test "a served session sends breakpoint and input events on the session topic" {
    const gpa = std.testing.allocator;
    var local: session_link.Local = undefined;
    try local.spawn(std.testing.io, test_paths.emulator, elf_path);
    errdefer local.child.kill(std.testing.io);
    const rx = try gpa.alloc(u8, 2 * Env.max_frame);
    defer gpa.free(rx);
    const tx = try gpa.alloc(u8, Env.max_frame);
    defer gpa.free(tx);
    var link: Link = undefined;
    link.open(local.transport(), rx, tx);
    try connect(&link);
    var seen: Seen = .{};

    try ok(try call(&link, &seen, proto.Point, .set_breakpoint, .{ .core = .cpu0, .address = 0x0200_0100 }));
    try ok(try call(&link, &seen, proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .session }));
    try ok(try call(&link, &seen, proto.Point, .set_breakpoint, .{ .core = .cpu0, .address = 0x0200_0200 }));
    try ok(try call(&link, &seen, proto.ScheduleInput, .input, .{ .core = .cpu0, .at_ns = 1_000_000, .kind = .button, .button = 1 }));
    try drain(&link, &seen);

    try std.testing.expectEqual(@as(usize, 2), seen.len);
    try std.testing.expectEqual(proto.EventKind.breakpoint_set, seen.events[0].kind);
    try std.testing.expectEqual(proto.Core.cpu0, seen.events[0].core);
    try std.testing.expectEqual(@as(u32, 0x0200_0200), seen.events[0].address);
    try std.testing.expectEqual(proto.EventKind.input_scheduled, seen.events[1].kind);

    local.end();
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try local.reap());
}
