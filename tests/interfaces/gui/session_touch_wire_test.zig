//! Over-the-wire test for a touch on the board pane's panel (RA8EMU-812): a
//! spawned `serve --stdio` session runs tests/fixtures/touch/touch.elf, which
//! reads the GT911 over I3C and stores the last contact in SRAM. A press on
//! the pane's shown panel goes through board_touch at the session's virtual
//! time, and the firmware's touch driver reads the same panel coordinates.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const test_paths = @import("test_paths");
const proto = ra8.rpc.session.rpc;
const session_link = gui_app.session_link;
const pane = gui_app.board_pane;
const touch = gui_app.board.touch;
const Link = session_link.Link;
const Env = proto.Client.Env;

const elf_path = "tests/fixtures/touch/touch.elf";
const width: u32 = 1024;
const height: u32 = 600;
/// touch.elf keeps x, y (u16 each) and a u32 count here.
const report_address: u32 = 0x2200_0100;

fn clock() i64 {
    return std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds();
}

/// Pump until the answer to `id` arrives.
fn answer(link: *Link, id: u32) ![]const u8 {
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
            .event => {},
        }
    }
    return error.Timeout;
}

fn run(link: *Link, mode: proto.RunMode, budget: u64) !void {
    _ = try answer(link, try link.send(proto.Run, .run, .{ .core = .cpu0, .mode = mode, .budget = budget }));
}

const Report = struct { x: u16, y: u16, count: u32 };

fn report(link: *Link) !Report {
    const read: proto.ReadMemory = .{ .core = .cpu0, .address = report_address, .length = 8 };
    const memory = try proto.decode(proto.Memory, try answer(link, try link.send(proto.ReadMemory, .read_memory, read)));
    const bytes = memory.bytes;
    return .{
        .x = std.mem.readInt(u16, bytes[0..2], .little),
        .y = std.mem.readInt(u16, bytes[2..4], .little),
        .count = std.mem.readInt(u32, bytes[4..8], .little),
    };
}

/// Press and release at (x, y) in window pixels, then let the firmware read it.
fn tapAt(link: *Link, shown: ra8.render.draw_list.Rect, x: i32, y: i32) !void {
    const now = try proto.decode(proto.U64, try answer(link, try link.send(proto.Now, .now, .{ .core = .cpu0 })));
    var drag: touch.Drag = .{};
    drag.down(shown, width, height, x, y, now.value);
    const gesture = drag.up(shown, width, height, x, y, now.value) orelse return error.NoGesture;
    try std.testing.expectEqual(proto.InputKind.tap, gesture.kind);
    const ack = try proto.decode(proto.Ack, try answer(link, try touch.send(link, .cpu0, gesture, now.value)));
    try std.testing.expectEqual(@as(u32, 1), ack.accepted);
    // The board catches up after each run: the contact lands at the end of
    // this run and the firmware reads it in the next.
    try run(link, .cont, 20_000);
    try run(link, .cont, 20_000);
}

test "a touch on the board pane's panel reaches the firmware's touch driver" {
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

    try run(&link, .run, 2_000);
    try std.testing.expectEqual(@as(u32, 0), (try report(&link)).count);

    const layout = pane.Layout.of(.{ .x = 0, .y = 0, .w = 480, .h = 320 });
    const shown = touch.shownIn(layout, width, height);
    const mid_x = shown.x + @divTrunc(shown.w, 2);
    const mid_y = shown.y + @divTrunc(shown.h, 2);
    try tapAt(&link, shown, mid_x, mid_y);
    const mid = touch.toPanel(shown, width, height, mid_x, mid_y);
    try std.testing.expectEqual(Report{ .x = mid.x, .y = mid.y, .count = 1 }, try report(&link));

    try tapAt(&link, shown, shown.x + shown.w - 1, shown.y + shown.h - 1);
    try std.testing.expectEqual(Report{ .x = width - 1, .y = height - 1, .count = 2 }, try report(&link));

    local.end();
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try local.reap());
}
