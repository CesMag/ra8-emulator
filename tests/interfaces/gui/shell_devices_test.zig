//! Host tests for the shell's device list (RA8EMU-792): only the response to
//! its own ask is kept, a refused or garbled reply becomes a note, lines split
//! into name and endpoint, and the devices leaf draws rows in place of its note.
//! Unplug (RA8EMU-801): the cell hit, the ask carrying the row's endpoint, the
//! re-list after the session answers, and the refusal note.
const std = @import("std");
const dark = &@import("gui_app").colors.palettes.dark;
const light = &@import("gui_app").colors.palettes.light;
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const status_capture = gui_app.status_capture;
const proto = ra8.rpc.session_rpc;
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;
const pane_layout = gui_app.pane_layout;
const frame = gui_app.shell_frame;
const panes = gui_app.shell_panes;
const status_bar = gui_app.status_bar;
const shell_devices = gui_app.shell_devices;
const Devices = shell_devices.Devices;
const Stdio = ra8.rpc.stdio_transport.Stdio;
const session_link = gui_app.session_link;
const Env = proto.Client.Env;

/// A link that has finished its greeting, writing into a pipe nobody answers.
const Wire = struct {
    link: session_link.Link = undefined,
    io: Stdio = .{},
    fds: [4]std.posix.fd_t = undefined,
    rx: [2 * Env.max_frame]u8 = undefined,
    tx: [Env.max_frame]u8 = undefined,

    fn open(self: *Wire) !void {
        const down = try std.Io.Threaded.pipe2(.{});
        const up = try std.Io.Threaded.pipe2(.{});
        self.fds = .{ down[0], down[1], up[0], up[1] };
        self.io = .{ .input = up[0], .output = down[1] };
        self.link.open(self.io.transport(), &self.rx, &self.tx);
        self.link.state = .{ .connected = .{ .version = proto.protocol_version, .caps = proto.capabilities } };
        self.link.client.peer_caps = proto.capabilities;
    }

    fn close(self: *Wire) void {
        for (self.fds) |fd| std.Io.Threaded.closeFd(fd);
    }
};

fn answer(devices: *Devices, id: u32, text: []const u8) !void {
    var bytes: [4200]u8 = undefined;
    const payload = try proto.encode(proto.PartList, .{ .text = text }, &bytes);
    devices.observe(.{ .response = .{ .id = id, .result = .{ .ok = payload } } });
}

test "only the response to its own ask is kept" {
    var devices: Devices = .{ .asked = 7 };
    try std.testing.expectEqual(@as(?[]const u8, null), devices.note());
    devices.observe(.{ .event = .{ .topic = @backingInt(proto.Topic.uart), .payload = "x" } });
    try answer(&devices, 6, "led@gpio:P106\n");
    try std.testing.expect(!devices.answered);
    try answer(&devices, 7, "lsm6dso@i2c:touch@0x6b\nmax17048@i2c:touch@0x36\n");
    try std.testing.expect(devices.answered);
    try answer(&devices, 7, "led@gpio:P106\n");
    var rows = devices.lines();
    try std.testing.expectEqualStrings("lsm6dso@i2c:touch@0x6b", rows.next().?);
    try std.testing.expectEqualStrings("max17048@i2c:touch@0x36", rows.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), rows.next());
    try std.testing.expectEqual(@as(?[]const u8, null), devices.note());
}

test "a refused, garbled or empty reply leaves a note" {
    var refused: Devices = .{ .asked = 1 };
    refused.observe(.{ .response = .{ .id = 1, .result = .{ .err = @fromBackingInt(@intCast(0x0003)) } } });
    try std.testing.expectEqualStrings("the session would not list its parts", refused.note().?);
    var garbled: Devices = .{ .asked = 1 };
    garbled.observe(.{ .response = .{ .id = 1, .result = .{ .ok = "" } } });
    try std.testing.expect(garbled.refused);
    var empty: Devices = .{ .asked = 1 };
    try answer(&empty, 1, "");
    try std.testing.expectEqualStrings("no parts fitted", empty.note().?);
}

test "a line splits at its first @ into name and endpoint" {
    const part = shell_devices.split("lsm6dso@i2c:touch@0x6b");
    try std.testing.expectEqualStrings("lsm6dso", part.name);
    try std.testing.expectEqualStrings("i2c:touch@0x6b", part.at);
    const bare = shell_devices.split("gpio:P106");
    try std.testing.expectEqualStrings("", bare.name);
    try std.testing.expectEqualStrings("gpio:P106", bare.at);
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

fn drawShell(gpa: std.mem.Allocator, theme: *const gui_app.colors.Theme, devices: *const Devices, pixels: *raster.Framebuffer, layout: *pane_layout.Layout, solved: anytype) !void {
    var list = draw_list.DrawList.init(gpa, 480, 320);
    defer list.deinit();
    const status: status_bar.Status = .{};
    var painter: panes.Panes = .{ .devices = devices };
    try frame.draw(&list, theme, .{ .layout = layout, .solved = solved, .strip = status_capture.strip(&status, .closed), .width = 480, .height = 320, .painter = painter.painter() });
    raster.draw(pixels, &list, font.atlas);
}

test "the devices leaf draws a row per part in place of its note" {
    const gpa = std.testing.allocator;
    var devices: Devices = .{ .asked = 1 };
    try answer(&devices, 1, "lsm6dso@i2c:touch@0x6b\n");
    var layout = try pane_layout.twoCore(gpa);
    defer layout.deinit();
    var solved = try frame.solve(&layout, gpa, 480, 320);
    defer solved.deinit(gpa);
    var pixels = try raster.Framebuffer.init(gpa, 480, 320);
    defer pixels.deinit(gpa);
    try drawShell(gpa, dark, &devices, &pixels, &layout, &solved);
    var leaves: usize = 0;
    for (solved.panes.items) |leaf| {
        const placed = layout.pane(leaf.index) orelse continue;
        if (placed.kind != .devices) continue;
        leaves += 1;
        const body = frame.bodyOf(leaf.area);
        const row: draw_list.Rect = .{ .x = body.x, .y = body.y + frame.pad, .w = body.w, .h = font.glyph_h };
        const column: i32 = @intCast(font.textWidth(shell_devices.name_cells));
        const name: draw_list.Rect = .{ .x = row.x, .y = row.y, .w = frame.pad + column, .h = row.h };
        const at: draw_list.Rect = .{ .x = row.x + frame.pad + column, .y = row.y, .w = body.w - frame.pad - column, .h = row.h };
        try std.testing.expect(holds(&pixels, name, dark.ink));
        try std.testing.expect(holds(&pixels, at, dark.muted));
        const below: draw_list.Rect = .{ .x = body.x, .y = row.y + shell_devices.row_h, .w = body.w, .h = body.h - frame.pad - shell_devices.row_h };
        try std.testing.expect(!holds(&pixels, below, dark.muted));
    }
    try std.testing.expect(leaves > 0);
}

test "the unplug cell sits at a row's right end and only it is hit" {
    const body: draw_list.Rect = .{ .x = 10, .y = 20, .w = 200, .h = 100 };
    const cell = shell_devices.unplugCell(body, 1);
    try std.testing.expectEqual(@as(?usize, 1), shell_devices.unplugRowAt(body, cell.x, cell.y));
    try std.testing.expectEqual(@as(?usize, null), shell_devices.unplugRowAt(body, body.x + frame.pad, cell.y));
    try std.testing.expectEqual(@as(?usize, null), shell_devices.unplugRowAt(body, cell.x, body.y));
    try std.testing.expectEqual(@as(?usize, null), shell_devices.unplugRowAt(body, cell.x, body.y + body.h + 1));
}

test "an unplug asks for the row's endpoint, and its answer asks the list again" {
    var wire: Wire = .{};
    try wire.open();
    defer wire.close();
    var devices: Devices = .{};
    devices.attach(&wire.link);
    const first = devices.asked.?;
    try answer(&devices, first, "lsm6dso@i2c:touch@0x6b\nmax17048@i2c:touch@0x36\n");
    try std.testing.expectEqualStrings("max17048@i2c:touch@0x36", devices.line(1).?);
    try std.testing.expect(!devices.unplug(&wire.link, 2));
    try std.testing.expect(devices.unplug(&wire.link, 1));
    try std.testing.expect(!devices.unplug(&wire.link, 0));
    const gone = devices.unplugging.?;
    devices.attach(&wire.link);
    try std.testing.expectEqual(@as(?u32, null), devices.asked);
    devices.observe(.{ .response = .{ .id = gone, .result = .{ .ok = "" } } });
    try std.testing.expect(!devices.unplug_refused);
    devices.attach(&wire.link);
    const again = devices.asked.?;
    try std.testing.expect(again != first);
    try answer(&devices, again, "lsm6dso@i2c:touch@0x6b\n");
    try std.testing.expectEqual(@as(?[]const u8, null), devices.line(1));
}

test "a refused unplug keeps the rows and leaves a note under them" {
    const gpa = std.testing.allocator;
    var devices: Devices = .{ .asked = 1 };
    try answer(&devices, 1, "lsm6dso@i2c:touch@0x6b\n");
    devices.unplugging = 5;
    devices.observe(.{ .response = .{ .id = 5, .result = .{ .err = @fromBackingInt(@intCast(0x0100)) } } });
    try std.testing.expect(devices.unplug_refused);
    try std.testing.expect(devices.want);
    try std.testing.expectEqualStrings("lsm6dso@i2c:touch@0x6b", devices.line(0).?);
    var list = draw_list.DrawList.init(gpa, 240, 120);
    defer list.deinit();
    const body: draw_list.Rect = .{ .x = 0, .y = 0, .w = 240, .h = 120 };
    try shell_devices.draw(&list, dark, body, &devices);
    var pixels = try raster.Framebuffer.init(gpa, 240, 120);
    defer pixels.deinit(gpa);
    raster.draw(&pixels, &list, font.atlas);
    try std.testing.expect(holds(&pixels, shell_devices.unplugCell(body, 0), dark.muted));
    const under: draw_list.Rect = .{ .x = 0, .y = frame.pad + shell_devices.row_h, .w = 240, .h = font.glyph_h };
    try std.testing.expect(holds(&pixels, under, dark.muted));
}

/// The devices leaf, listing one part, in `theme`: FNV-1a over the leaf's
/// own pixels, so only the devices pane moves this golden.
fn devicesDigest(theme: *const gui_app.colors.Theme) !u64 {
    const gpa = std.testing.allocator;
    var devices: Devices = .{ .asked = 1 };
    try answer(&devices, 1, "lsm6dso@i2c:touch@0x6b\n");
    var layout = try pane_layout.twoCore(gpa);
    defer layout.deinit();
    var solved = try frame.solve(&layout, gpa, 480, 320);
    defer solved.deinit(gpa);
    var pixels = try raster.Framebuffer.init(gpa, 480, 320);
    defer pixels.deinit(gpa);
    try drawShell(gpa, theme, &devices, &pixels, &layout, &solved);
    var hash = std.hash.Fnv1a_64.init();
    for (solved.panes.items) |leaf| {
        const placed = layout.pane(leaf.index) orelse continue;
        if (placed.kind != .devices) continue;
        var y = leaf.area.y;
        while (y < leaf.area.y + leaf.area.h) : (y += 1) {
            const start: usize = @intCast(y * 480 + leaf.area.x);
            hash.update(std.mem.sliceAsBytes(pixels.pixels[start..][0..@intCast(leaf.area.w)]));
        }
        return hash.final();
    }
    return error.NoDevicesLeaf;
}

test "the devices leaf rasterises to a pinned golden in each palette" {
    try std.testing.expectEqual(@as(u64, 4050192518716919535), try devicesDigest(dark));
    try std.testing.expectEqual(@as(u64, 1810762630783763910), try devicesDigest(light));
}
