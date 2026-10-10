//! Host tests for the devices leaf's fault cell (RA8EMU-817): the mode cycle
//! and its asks, the cell sitting just left of the unplug cell and its hit
//! test, and the mode moving only on the session's ok.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const proto = ra8.rpc.session_rpc;
const draw_list = ra8.render.draw_list;
const font = ra8.render.font;
const frame = gui_app.shell_frame;
const shell_devices = gui_app.shell_devices;
const fault = gui_app.shell_fault;
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

const body: draw_list.Rect = .{ .x = 10, .y = 20, .w = 300, .h = 120 };

test "the cycle steps through every mode and back to none" {
    var mode: usize = 0;
    var seen: [fault.modes.len + 1][]const u8 = undefined;
    for (&seen) |*label| {
        label.* = fault.label(mode);
        mode = fault.next(mode);
    }
    try std.testing.expectEqual(@as(usize, 0), mode);
    try std.testing.expectEqualStrings(fault.none_mark, seen[0]);
    for (fault.modes, seen[1..]) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "a mode asks set_fault with the endpoint and none asks clear_fault" {
    var buf: [64]u8 = undefined;
    const set = try fault.ask(&buf, "i2c:touch@0x36", 2);
    try std.testing.expectEqual(proto.Method.set_fault, set.method);
    try std.testing.expectEqualStrings("@i2c:touch@0x36=nack:2", set.text);
    const clear = try fault.ask(&buf, "i2c:touch@0x36", 0);
    try std.testing.expectEqual(proto.Method.clear_fault, clear.method);
    try std.testing.expectEqualStrings("i2c:touch@0x36", clear.text);
    var tiny: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, fault.ask(&tiny, "i2c:touch@0x36", 1));
}

test "the fault cell sits just left of the unplug cell and hits its own row" {
    for ([_]usize{ 0, 3 }) |row| {
        const cell = fault.cell(body, row);
        const unplug = shell_devices.unplugCell(body, row);
        try std.testing.expectEqual(unplug.y, cell.y);
        try std.testing.expectEqual(@as(i32, @intCast(font.textWidth(fault.cells))), cell.w);
        try std.testing.expect(cell.x + cell.w < unplug.x);
        try std.testing.expectEqual(@as(?usize, row), fault.rowAt(body, cell.x, cell.y));
        try std.testing.expectEqual(@as(?usize, row), fault.rowAt(body, cell.x + cell.w - 1, cell.y + cell.h - 1));
        try std.testing.expectEqual(@as(?usize, null), fault.rowAt(body, unplug.x, unplug.y));
        try std.testing.expectEqual(@as(?usize, null), fault.rowAt(body, cell.x - 1, cell.y));
    }
    try std.testing.expectEqual(@as(?usize, null), fault.rowAt(body, body.x + body.w + 1, body.y + frame.pad));
    try std.testing.expectEqual(@as(?usize, null), fault.rowAt(body, fault.cell(body, 0).x, body.y));
}

fn answerOk(faults: *fault.Faults, id: u32) bool {
    return faults.observe(.{ .response = .{ .id = id, .result = .{ .ok = "" } } });
}

test "a cycle moves the mode only on the session's ok" {
    var wire: Wire = .{};
    try wire.open();
    defer wire.close();
    var faults: fault.Faults = .{};
    const at = "i2c:touch@0x36";

    try std.testing.expect(faults.cycle(&wire.link, at));
    const first = faults.asked.?;
    try std.testing.expect(!faults.cycle(&wire.link, at));
    try std.testing.expectEqual(@as(usize, 0), faults.modeOf(at));
    try std.testing.expect(!faults.observe(.{ .event = .{ .topic = @backingInt(proto.Topic.session), .payload = "x" } }));
    try std.testing.expect(!answerOk(&faults, first + 1));
    try std.testing.expect(answerOk(&faults, first));
    try std.testing.expectEqual(@as(usize, 1), faults.modeOf(at));
    try std.testing.expectEqual(@as(usize, 0), faults.modeOf("i2c:touch@0x6b"));

    try std.testing.expect(faults.cycle(&wire.link, at));
    const refused = faults.observe(.{ .response = .{ .id = faults.asked.?, .result = .{ .err = @fromBackingInt(@intCast(0x0100)) } } });
    try std.testing.expect(refused and faults.refused);
    try std.testing.expectEqual(@as(usize, 1), faults.modeOf(at));

    var mode: usize = 1;
    while (mode != 0) : (mode = fault.next(mode)) {
        try std.testing.expect(faults.cycle(&wire.link, at));
        try std.testing.expect(!faults.refused);
        try std.testing.expect(answerOk(&faults, faults.asked.?));
        try std.testing.expectEqual(fault.next(mode), faults.modeOf(at));
    }
    try std.testing.expectEqual(@as(usize, 1), faults.used);
}
