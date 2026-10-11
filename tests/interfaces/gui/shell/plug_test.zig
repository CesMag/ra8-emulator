//! Host tests for the shell's plug picker (RA8EMU-802): Enter sends plug
//! with the typed spec once, the answer clears the field or leaves a
//! refusal note, only its own answer counts, and the devices leaf draws
//! the field at its foot under the rows.
const std = @import("std");
const dark = &@import("gui_app").colors.palettes.dark;
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const proto = ra8.rpc.session.rpc;
const draw_list = ra8.render.draw_list;
const platform = gui_app.platform;
const shell_plug = gui_app.shell.plug;
const shell_field = gui_app.shell.field;
const shell_devices = gui_app.shell.devices;
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

const body: draw_list.Rect = .{ .x = 0, .y = 0, .w = 300, .h = 120 };

/// A picker drawn once in `body` with its field focused and `spec` typed
/// (one text event holds at most 8 bytes).
fn typed(plug: *shell_plug.Plug, list: *draw_list.DrawList, devices: *const shell_devices.Devices, spec: []const u8) !void {
    try plug.init();
    try shell_plug.draw(list, dark, body, devices, plug);
    const field = shell_plug.fieldRect(body);
    try std.testing.expect(plug.press(field.x + 2, field.y + 2));
    if (spec.len > 0) try std.testing.expect(plug.handle(.{ .text = platform.Text.of(spec) }));
}

fn enter(plug: *shell_plug.Plug) void {
    _ = plug.handle(.{ .key = .{ .code = 0x0D, .down = true } });
}

test "nothing is sent until Enter, then one plug carries the spec" {
    var wire: Wire = .{};
    try wire.open();
    defer wire.close();
    var list = draw_list.DrawList.init(std.testing.allocator, 300, 120);
    defer list.deinit();
    const devices: shell_devices.Devices = .{ .answered = true };
    var plug: shell_plug.Plug = .{};
    try typed(&plug, &list, &devices, "led@gpio");
    try std.testing.expect(!plug.attach(&wire.link));
    enter(&plug);
    try std.testing.expect(plug.attach(&wire.link));
    try std.testing.expect(plug.asking != null);
    enter(&plug);
    try std.testing.expect(!plug.attach(&wire.link));
}

test "an ack clears the field and asks the list again" {
    var wire: Wire = .{};
    try wire.open();
    defer wire.close();
    var list = draw_list.DrawList.init(std.testing.allocator, 300, 120);
    defer list.deinit();
    const devices: shell_devices.Devices = .{ .answered = true };
    var plug: shell_plug.Plug = .{};
    try typed(&plug, &list, &devices, "led@gpio");
    enter(&plug);
    try std.testing.expect(plug.attach(&wire.link));
    const id = plug.asking.?;
    try std.testing.expect(!plug.observe(.{ .response = .{ .id = id + 1, .result = .{ .ok = "" } } }));
    try std.testing.expect(!plug.observe(.{ .event = .{ .topic = @backingInt(proto.Topic.uart), .payload = "x" } }));
    try std.testing.expect(plug.observe(.{ .response = .{ .id = id, .result = .{ .ok = "" } } }));
    try std.testing.expect(!plug.refused);
    try std.testing.expectEqual(@as(usize, 0), plug.field.value().len);
    try std.testing.expectEqual(@as(?u32, null), plug.asking);
}

test "a refusal keeps the text and leaves a note" {
    var wire: Wire = .{};
    try wire.open();
    defer wire.close();
    var list = draw_list.DrawList.init(std.testing.allocator, 300, 120);
    defer list.deinit();
    const devices: shell_devices.Devices = .{ .answered = true };
    var plug: shell_plug.Plug = .{};
    try typed(&plug, &list, &devices, "bad@gpio");
    enter(&plug);
    try std.testing.expect(plug.attach(&wire.link));
    try std.testing.expect(plug.observe(.{ .response = .{ .id = plug.asking.?, .result = .{ .err = @fromBackingInt(@intCast(0x0100)) } } }));
    try std.testing.expect(plug.refused);
    try std.testing.expectEqualStrings("bad@gpio", plug.field.value());
}

test "an empty field sends nothing" {
    var wire: Wire = .{};
    try wire.open();
    defer wire.close();
    var list = draw_list.DrawList.init(std.testing.allocator, 300, 120);
    defer list.deinit();
    const devices: shell_devices.Devices = .{ .answered = true };
    var plug: shell_plug.Plug = .{};
    try typed(&plug, &list, &devices, "");
    enter(&plug);
    try std.testing.expect(!plug.attach(&wire.link));
}

test "the field sits at the leaf's foot, below the rows" {
    const field = shell_plug.fieldRect(body);
    const rows = shell_plug.rowsRect(body);
    try std.testing.expectEqual(@as(i32, shell_field.height), field.h);
    try std.testing.expect(field.y + field.h <= body.y + body.h);
    try std.testing.expect(rows.y + rows.h <= field.y - shell_devices.row_h);
}

test "the leaf draws its note, then the field's placeholder" {
    var list = draw_list.DrawList.init(std.testing.allocator, 300, 120);
    defer list.deinit();
    const devices: shell_devices.Devices = .{ .answered = true };
    var plug: shell_plug.Plug = .{};
    try plug.init();
    try shell_plug.draw(&list, dark, body, &devices, &plug);
    var glyphs: usize = 0;
    for (list.commands.items) |command| {
        if (command.shape == .glyph) glyphs += 1;
    }
    const note = "no parts fitted".len - 2;
    const words = shell_plug.placeholder.len - 5;
    try std.testing.expect(glyphs >= note + words);
}
