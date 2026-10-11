//! Host tests for the shell's console feed (RA8EMU-787): uart events land in
//! the log at their board time, nothing else does, a local session's banner
//! arrives stamped, and the console leaf draws the log in place of its note.
const std = @import("std");
const dark = &@import("gui_app").colors.palettes.dark;
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const status_capture = gui_app.status_capture;
const test_paths = @import("test_paths");
const proto = ra8.rpc.session_rpc;
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;
const pane_layout = gui_app.pane_layout;
const frame = gui_app.shell_frame;
const panes = gui_app.shell_panes;
const console_pane = gui_app.console_pane;
const session_link = gui_app.session_link;
const status_bar = gui_app.status_bar;
const Console = gui_app.shell_console.Console;

const Env = proto.Client.Env;
const uart_image = "tests/fixtures/uart/uart_irq_echo.elf";
const banner = "uart_irq_echo ready";

fn uart(console: *Console, text: []const u8, at_ns: u64) !void {
    var bytes: [proto.max_payload]u8 = undefined;
    const payload = try proto.encode(proto.Uart, .{ .core = .cpu0, .channel = 8, .virtual_ns = at_ns, .bytes = text }, &bytes);
    try console.observe(.{ .event = .{ .topic = @backingInt(proto.Topic.uart), .payload = payload } });
}

test "uart events land in the log at their own board time" {
    var console = Console.init(std.testing.allocator);
    defer console.deinit();
    try std.testing.expect(!console.hasOutput());
    try uart(&console, "hi\n", 50);
    try uart(&console, "x", 70);
    try std.testing.expect(console.hasOutput());
    const lines = console.log.lines();
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqualStrings("hi", lines[0].text);
    try std.testing.expectEqual(@as(u64, 50), lines[0].at_ns);
    try std.testing.expectEqualStrings("x", console.log.partial());
}

test "responses and other topics leave the log alone" {
    var console = Console.init(std.testing.allocator);
    defer console.deinit();
    try console.observe(.{ .response = .{ .id = 1, .result = .{ .ok = "hi\n" } } });
    try console.observe(.{ .event = .{ .topic = @backingInt(proto.Topic.stop), .payload = "hi\n" } });
    try std.testing.expect(!console.hasOutput());
}

/// Pump `link` into the status bar and console until `done`, for ten seconds.
fn pumpUntil(link: *session_link.Link, status: *status_bar.Status, console: *Console, comptime done: fn (*const session_link.Link, *const status_bar.Status, *const Console) bool) !void {
    const deadline = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() + 10_000;
    while (!done(link, status, console)) {
        if (std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() > deadline) return error.Timeout;
        console.attach(link);
        if (link.pump()) |arrival| {
            status.observe(link, arrival);
            try console.observe(arrival);
        } else try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn connected(link: *const session_link.Link, _: *const status_bar.Status, _: *const Console) bool {
    return link.state == .connected;
}

fn loaded(_: *const session_link.Link, status: *const status_bar.Status, console: *const Console) bool {
    return console.subscribed and status.load_id == null and status.pc_id == null and status.image != null;
}

fn greeted(_: *const session_link.Link, _: *const status_bar.Status, console: *const Console) bool {
    for (console.log.lines()) |line| if (std.mem.indexOf(u8, line.text, banner) != null) return true;
    return false;
}

test "a local session's banner reaches the console stamped with board time" {
    const gpa = std.testing.allocator;
    var local: session_link.Local = undefined;
    try local.spawn(std.testing.io, test_paths.emulator, uart_image);
    errdefer local.child.kill(std.testing.io);
    const rx = try gpa.alloc(u8, 2 * Env.max_frame);
    defer gpa.free(rx);
    const tx = try gpa.alloc(u8, Env.max_frame);
    defer gpa.free(tx);
    var link: session_link.Link = undefined;
    link.open(local.transport(), rx, tx);
    var status: status_bar.Status = .{};
    var console = Console.init(gpa);
    defer console.deinit();
    try pumpUntil(&link, &status, &console, connected);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, uart_image, gpa, .limited(1 << 20));
    defer gpa.free(bytes);
    try status.load(&link, uart_image, bytes);
    try pumpUntil(&link, &status, &console, loaded);
    _ = try link.send(proto.Run, .run, .{ .core = .cpu0, .mode = .run, .budget = 100_000 });
    try pumpUntil(&link, &status, &console, greeted);
    for (console.log.lines()) |line| if (std.mem.indexOf(u8, line.text, banner) != null) {
        try std.testing.expect(line.at_ns > 0);
    };

    link.close();
    local.end();
    _ = try local.reap();
}

fn holds(pixels: *const raster.Framebuffer, area: draw_list.Rect, color: draw_list.Color) bool {
    var y = area.y;
    while (y < area.y + area.h) : (y += 1) {
        var x = area.x;
        while (x < area.x + area.w) : (x += 1) {
            if (std.meta.eql(pixels.at(@intCast(x), @intCast(y)), color)) return true;
        }
    }
    return false;
}

test "the console leaf draws the log in place of its note" {
    const gpa = std.testing.allocator;
    var console = Console.init(gpa);
    defer console.deinit();
    try uart(&console, "booted\n", 1_000);
    var layout = try pane_layout.twoCore(gpa);
    defer layout.deinit();
    var solved = try frame.solve(&layout, gpa, 480, 320);
    defer solved.deinit(gpa);
    var list = draw_list.DrawList.init(gpa, 480, 320);
    defer list.deinit();
    var pixels = try raster.Framebuffer.init(gpa, 480, 320);
    defer pixels.deinit(gpa);
    const status: status_bar.Status = .{};
    var painter: panes.Panes = .{ .console = &console };
    try frame.draw(&list, dark, .{ .layout = &layout, .solved = &solved, .strip = status_capture.strip(&status, .closed), .width = 480, .height = 320, .painter = painter.painter() });
    raster.draw(&pixels, &list, font.atlas);
    var consoles: usize = 0;
    for (solved.panes.items) |leaf| {
        const body = frame.bodyOf(leaf.area);
        const placed = layout.pane(leaf.index) orelse continue;
        if (placed.kind != .console) continue;
        consoles += 1;
        try std.testing.expect(holds(&pixels, body, dark.ink));
        try std.testing.expect(holds(&pixels, body, dark.background));
    }
    try std.testing.expect(consoles > 0);
}
