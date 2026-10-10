//! Over-the-wire test for a board pane click (RA8EMU-814): a spawned
//! `serve --stdio` session runs tests/fixtures/gpio/buttons.elf, which
//! mirrors SW1 onto LED1. Clicking SW1 through the pane's input handler at
//! the session's virtual time turns the LED on.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const test_paths = @import("test_paths");
const proto = ra8.rpc.session_rpc;
const session_link = gui_app.session_link;
const pane = gui_app.board_pane;
const capture = gui_app.board_capture;
const input = gui_app.board_input;
const Link = session_link.Link;
const Env = proto.Client.Env;

const elf_path = "tests/fixtures/gpio/buttons.elf";

fn clock() i64 {
    return std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds();
}

/// Pump until the answer to `id` arrives, folding LED events into `leds`.
fn answer(link: *Link, leds: *pane.Leds, id: u32) ![]const u8 {
    const deadline = clock() + 10_000;
    while (clock() < deadline) {
        if (link.state != .connected) return error.LinkLost;
        const arrival = link.pump() orelse {
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
            continue;
        };
        switch (arrival) {
            .response => |response| if (response.id == id) return switch (response.result) {
                .ok => |bytes| bytes,
                .err => error.Refused,
            },
            .event => |event| if (event.topic == @backingInt(proto.Topic.session)) {
                capture.observe(leds, try proto.decode(proto.SessionEvent, event.payload));
            },
        }
    }
    return error.Timeout;
}

/// `run` starts the image; once started, the session only continues it.
fn run(link: *Link, leds: *pane.Leds, mode: proto.RunMode, budget: u64) !void {
    _ = try answer(link, leds, try link.send(proto.Run, .run, .{ .core = .cpu0, .mode = mode, .budget = budget }));
}

test "clicking SW1 on the board pane reaches the firmware" {
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
    const deadline = clock() + 10_000;
    while (link.state == .connecting and clock() < deadline) {
        _ = link.pump();
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(link.state == .connected);

    var leds: pane.Leds = .{};
    _ = try answer(&link, &leds, try link.send(proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .session }));
    try run(&link, &leds, .run, 2_000);
    try std.testing.expect(!leds.on[0]);

    const layout = pane.Layout.of(.{ .x = 0, .y = 0, .w = 480, .h = 320 });
    const sw1 = layout.switches[0];
    const x = sw1.x + @divTrunc(sw1.w, 2);
    const y = sw1.y + @divTrunc(sw1.h, 2);
    var press: input.Press = .{};
    press.down(layout, x, y);
    const clicked = press.up(layout, x, y) orelse return error.NoClick;
    const now = try proto.decode(proto.U64, try answer(&link, &leds, try link.send(proto.Now, .now, .{ .core = .cpu0 })));
    const ack = try proto.decode(proto.Ack, try answer(&link, &leds, try input.send(&link, .cpu0, clicked, now.value)));
    try std.testing.expectEqual(@as(u32, 1), ack.accepted);

    // Without a boundary the board catches up after each run, so the press
    // lands at the end of this run and the firmware reads it in the next.
    try run(&link, &leds, .cont, 20_000);
    try run(&link, &leds, .cont, 20_000);
    try std.testing.expect(leds.on[0]);

    local.end();
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try local.reap());
}
