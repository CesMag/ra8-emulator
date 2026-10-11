//! Over-the-wire test for LED changes on the session topic (RA8EMU-811): a
//! spawned `serve --stdio` session runs tests/fixtures/gpio/blink.elf and a
//! client subscribed to session sees LED 0 go on, off, on, off in order.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const test_paths = @import("test_paths");
const proto = ra8.rpc.session.rpc;
const session_link = gui_app.session_link;
const Link = session_link.Link;
const Env = proto.Client.Env;

const elf_path = "tests/fixtures/gpio/blink.elf";

const Leds = struct {
    addresses: [8]u32 = undefined,
    len: usize = 0,

    fn keep(self: *Leds, event: Env.Event) !void {
        if (event.topic != @backingInt(proto.Topic.session)) return;
        const got = try proto.decode(proto.SessionEvent, event.payload);
        if (got.kind != .led_changed) return;
        try std.testing.expectEqual(proto.Core.cpu0, got.core);
        if (self.len == self.addresses.len) return error.TooManyEvents;
        self.addresses[self.len] = got.address;
        self.len += 1;
    }
};

fn clock() i64 {
    return std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds();
}

/// Pump until `done` holds or ten seconds pass, keeping LED events.
fn pumpUntil(link: *Link, leds: *Leds, id: ?u32) !void {
    const deadline = clock() + 10_000;
    var answered = id == null;
    var quiet_until: i64 = std.math.maxInt(i64);
    while (clock() < deadline and clock() < quiet_until) {
        if (link.state != .connected and link.state != .connecting) return error.LinkLost;
        const arrival = link.pump() orelse {
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
            continue;
        };
        switch (arrival) {
            .response => |response| if (id != null and response.id == id.?) {
                try std.testing.expect(response.result == .ok);
                answered = true;
                quiet_until = clock() + 200;
            },
            .event => |event| try leds.keep(event),
        }
    }
    try std.testing.expect(answered);
}

test "a served session sends each LED change on the session topic in order" {
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
    var leds: Leds = .{};
    const deadline = clock() + 10_000;
    while (link.state == .connecting and clock() < deadline) {
        _ = link.pump();
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(link.state == .connected);

    try pumpUntil(&link, &leds, try link.send(proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .session }));
    try pumpUntil(&link, &leds, try link.send(proto.Run, .run, .{ .core = .cpu0, .mode = .run, .budget = 20_000 }));

    try std.testing.expectEqualSlices(u32, &.{ 0x100, 0x000, 0x100, 0x000 }, leds.addresses[0..leds.len]);

    local.end();
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try local.reap());
}
