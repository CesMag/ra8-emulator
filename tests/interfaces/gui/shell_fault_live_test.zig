//! Host tests for the devices leaf's fault cell wired into the shell
//! (RA8EMU-817): a spawned `serve --stdio` takes a click on a row's fault
//! cell through every mode and back, and reports each one as a fault_set
//! or fault_cleared session event; and a faulted row through raster.draw
//! is pinned as a golden.
const std = @import("std");
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
const status_bar = gui_app.status_bar;
const shell_devices = gui_app.shell_devices;
const fault = gui_app.shell_fault;
const session_link = gui_app.session_link;
const Link = session_link.Link;
const Env = proto.Client.Env;

const image_path = "tests/fixtures/fpu/fp_basic.elf";
const part = "max17048@i2c:riic@0x36";
const endpoint = "i2c:riic@0x36";
const width = 480;
const height = 320;

/// The devices leaf and its faults, fed in the shell's own order
/// (shell_loop pump), plus a count of the session's fault events.
const Watch = struct {
    devices: shell_devices.Devices = .{},
    faults: fault.Faults = .{},
    plugging: ?u32 = null,
    plugged: bool = false,
    set: usize = 0,
    cleared: usize = 0,

    fn observe(self: *Watch, arrival: session_link.Arrival) void {
        switch (arrival) {
            .event => |event| if (event.topic == @backingInt(proto.Topic.session)) {
                const said = proto.decode(proto.SessionEvent, event.payload) catch return;
                if (said.kind == .fault_set) self.set += 1;
                if (said.kind == .fault_cleared) self.cleared += 1;
            },
            .response => |response| if (self.plugging == response.id) {
                self.plugging = null;
                self.plugged = response.result == .ok;
                self.devices.want = true;
            },
        }
        self.devices.observe(arrival);
        if (self.faults.observe(arrival)) self.devices.want = true;
    }
};

fn nowMs() i64 {
    return std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds();
}

/// Pump `link` into `watch` for up to ten seconds, until `done` holds.
fn pumpUntil(link: *Link, watch: *Watch, comptime done: fn (*const Watch, *const Link) bool) !void {
    const deadline = nowMs() + 10_000;
    while (nowMs() < deadline) {
        if (link.state != .connecting and link.state != .connected) return error.LinkDown;
        watch.devices.attach(link);
        if (link.pump()) |arrival| {
            watch.observe(arrival);
            continue;
        }
        if (done(watch, link)) return;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.Timeout;
}

fn connected(_: *const Watch, link: *const Link) bool {
    return link.state == .connected;
}

fn listed(watch: *const Watch, _: *const Link) bool {
    return watch.plugging == null and watch.devices.answered and watch.devices.asked == null and !watch.devices.want;
}

fn answered(watch: *const Watch, link: *const Link) bool {
    return watch.faults.asked == null and listed(watch, link);
}

/// The row the part on `endpoint` sits on.
fn rowOf(devices: *const shell_devices.Devices) !usize {
    var row: usize = 0;
    while (devices.line(row)) |line| : (row += 1) {
        if (std.mem.eql(u8, shell_devices.split(line).at, endpoint)) return row;
    }
    return error.NotListed;
}

/// Press the fault cell of `row` in the first devices leaf.
fn press(watch: *Watch, link: *Link, row: usize) !void {
    const gpa = std.testing.allocator;
    var layout = try pane_layout.twoCore(gpa);
    defer layout.deinit();
    var solved = try frame.solve(&layout, gpa, width, height);
    defer solved.deinit(gpa);
    for (solved.panes.items) |leaf| {
        const placed = layout.pane(leaf.index) orelse continue;
        if (placed.kind != .devices) continue;
        const cell = fault.cell(frame.bodyOf(leaf.area), row);
        try std.testing.expect(watch.faults.clickIn(link, &watch.devices, &layout, &solved, cell.x + 1, cell.y + 1));
        return;
    }
    return error.NoDevicesLeaf;
}

test "a fault cell click walks a served part through every mode and back, each one reported" {
    const gpa = std.testing.allocator;
    var local: session_link.Local = undefined;
    try local.spawn(std.testing.io, test_paths.emulator, image_path);
    errdefer local.child.kill(std.testing.io);
    const rx = try gpa.alloc(u8, 2 * Env.max_frame);
    defer gpa.free(rx);
    const tx = try gpa.alloc(u8, Env.max_frame);
    defer gpa.free(tx);
    var link: Link = undefined;
    link.open(local.transport(), rx, tx);
    var watch: Watch = .{};
    try pumpUntil(&link, &watch, connected);
    _ = try link.send(proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .session });
    watch.plugging = try link.send(proto.PartSpec, .plug, .{ .core = .cpu0, .text = part });
    try pumpUntil(&link, &watch, listed);
    try std.testing.expect(watch.plugged);

    var mode: usize = 0;
    var sets: usize = 0;
    while (true) {
        try press(&watch, &link, try rowOf(&watch.devices));
        try pumpUntil(&link, &watch, answered);
        mode = fault.next(mode);
        try std.testing.expect(!watch.faults.refused);
        try std.testing.expectEqual(mode, watch.faults.modeOf(endpoint));
        if (mode == 0) break;
        sets += 1;
        try std.testing.expectEqual(sets, watch.set);
        try std.testing.expectEqual(@as(usize, 0), watch.cleared);
    }
    try std.testing.expectEqual(fault.modes.len, watch.set);
    try std.testing.expectEqual(@as(usize, 1), watch.cleared);
    _ = try rowOf(&watch.devices);

    local.end();
    while (link.state == .connected) {
        if (link.pump() == null) try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try local.reap());
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

test "a faulted row draws its mode in ink beside an unfaulted row's muted mark" {
    const gpa = std.testing.allocator;
    var devices: shell_devices.Devices = .{ .asked = 1 };
    var bytes: [256]u8 = undefined;
    const listing = try proto.encode(proto.PartList, .{ .text = part ++ "\nlsm6dso@i2c:riic@0x6b\n" }, &bytes);
    devices.observe(.{ .response = .{ .id = 1, .result = .{ .ok = listing } } });
    var faults: fault.Faults = .{ .asked = 2 };
    faults.pending.len = endpoint.len;
    faults.pending.mode = 1;
    @memcpy(faults.pending.at[0..endpoint.len], endpoint);
    try std.testing.expect(faults.observe(.{ .response = .{ .id = 2, .result = .{ .ok = "" } } }));

    var layout = try pane_layout.twoCore(gpa);
    defer layout.deinit();
    var solved = try frame.solve(&layout, gpa, width, height);
    defer solved.deinit(gpa);
    var list = draw_list.DrawList.init(gpa, width, height);
    defer list.deinit();
    const status: status_bar.Status = .{};
    var painter: panes.Panes = .{ .devices = &devices, .faults = &faults };
    try frame.draw(&list, .{ .layout = &layout, .solved = &solved, .strip = status_capture.strip(&status, .closed), .width = width, .height = height, .painter = painter.painter() });
    var pixels = try raster.Framebuffer.init(gpa, width, height);
    defer pixels.deinit(gpa);
    raster.draw(&pixels, &list, font.atlas);

    var leaves: usize = 0;
    for (solved.panes.items) |leaf| {
        const placed = layout.pane(leaf.index) orelse continue;
        if (placed.kind != .devices) continue;
        leaves += 1;
        const body = frame.bodyOf(leaf.area);
        try std.testing.expect(holds(&pixels, fault.cell(body, 0), frame.ink));
        try std.testing.expect(!holds(&pixels, fault.cell(body, 1), frame.ink));
        try std.testing.expect(holds(&pixels, fault.cell(body, 1), frame.muted));
    }
    try std.testing.expect(leaves > 0);
    const digest = std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(pixels.pixels));
    try std.testing.expectEqual(@as(u64, 15921208307697644887), digest);
}
