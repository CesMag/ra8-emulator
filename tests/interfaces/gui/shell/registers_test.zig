//! Host tests for the shell's registers leaf (RA8EMU-821): the wire names
//! follow the pane's order, a batch asks one read per shown register only
//! once due, its last answer publishes it and the next marks what changed, a
//! stop of the bound core makes a batch due, a refused read keeps the last
//! values with a note, a batch sent before a load is dropped, and the
//! registers leaf draws in place of its note.
const std = @import("std");
const dark = &@import("gui_app").colors.palettes.dark;
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const status_capture = gui_app.status.capture;
const proto = ra8.rpc.session.rpc;
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;
const pane_layout = gui_app.pane_layout;
const frame = gui_app.shell.frame;
const panes = gui_app.shell.panes;
const status_bar = gui_app.status.bar;
const registers_pane = gui_app.registers_pane;
const registers_capture = gui_app.registers_capture;
const shell_registers = gui_app.shell.registers;
const Registers = shell_registers.Registers;
const Stdio = ra8.rpc.stdio_transport.Stdio;
const session_link = gui_app.session_link;
const Env = proto.Client.Env;

const count = registers_capture.shown.len;

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

/// A batch in flight with ids `first`, `first + 1`, ...
fn inFlight(core: proto.Core, first: u32) Registers {
    var model: Registers = .{ .core = core, .left = count };
    for (&model.asked, 0..) |*asked, index| asked.* = first + @as(u32, @intCast(index));
    return model;
}

fn answer(model: *Registers, id: u32, value: u32) !void {
    var bytes: [16]u8 = undefined;
    const payload = try proto.encode(proto.U32, .{ .value = value }, &bytes);
    model.observe(.{ .response = .{ .id = id, .result = .{ .ok = payload } } });
}

fn stop(model: *Registers, core: proto.Core) !void {
    var bytes: [32]u8 = undefined;
    const payload = try proto.encode(proto.Stopped, .{ .core = core, .reason = .stepped, .address = 0x100, .detail = 0 }, &bytes);
    model.observe(.{ .event = .{ .topic = @backingInt(proto.Topic.stop), .payload = payload } });
}

test "the wire names follow the pane's order" {
    for (registers_capture.shown, shell_registers.wire) |which, register| {
        try std.testing.expectEqualStrings(@tagName(which), @tagName(register));
    }
}

test "a batch asks one read per shown register, and only once due" {
    var wire: Wire = .{};
    try wire.open();
    defer wire.close();
    var model: Registers = .{ .core = .cpu0 };
    model.attach(&wire.link);
    try std.testing.expectEqual(@as(usize, 0), model.left);
    model.reload();
    model.attach(&wire.link);
    // More registers than pending slots: the first attach fills the table.
    try std.testing.expectEqual(@as(usize, proto.pending_slots), model.left);
    try std.testing.expectEqual(@as(usize, proto.pending_slots), model.next);
    for (model.asked[0..model.next], 0..) |asked, index| {
        for (model.asked[0..index]) |earlier| try std.testing.expect(earlier.? != asked.?);
    }
    const first = model.asked[0];
    model.want = true;
    model.attach(&wire.link);
    try std.testing.expectEqual(first, model.asked[0]);
    try std.testing.expect(model.want);
}

test "the last answer publishes the batch, and the next marks what changed" {
    var model = inFlight(.cpu1, 1);
    for (0..count) |index| {
        try std.testing.expectEqual(@as(?shell_registers.Snapshot, null), model.now);
        try answer(&model, @intCast(1 + index), @intCast(index));
    }
    try std.testing.expectEqual(@as(u32, 5), model.now.?.values[5]);
    try std.testing.expectEqual(@as(?shell_registers.Snapshot, null), model.before);
    try std.testing.expectEqual(@as(?[]const u8, null), model.note());
    const first = model.now.?;
    var next = inFlight(.cpu1, 101);
    next.now = first;
    for (0..count) |index| try answer(&next, @intCast(101 + index), if (index == 0) 99 else @intCast(index));
    try std.testing.expect(next.now.?.changedAt(next.before, 0));
    try std.testing.expect(!next.now.?.changedAt(next.before, 1));
}

test "an answer to another ask is ignored" {
    var model = inFlight(.cpu0, 10);
    try answer(&model, 9, 1);
    try answer(&model, 10 + count, 1);
    try std.testing.expectEqual(count, model.left);
}

test "a stop of the bound core makes a batch due; the other core's does not" {
    var model: Registers = .{ .core = .cpu0 };
    try stop(&model, .cpu1);
    try std.testing.expect(!model.want);
    model.observe(.{ .event = .{ .topic = @backingInt(proto.Topic.uart), .payload = "x" } });
    try std.testing.expect(!model.want);
    try stop(&model, .cpu0);
    try std.testing.expect(model.want);
}

test "a refused read keeps the last values and leaves a note" {
    var model = inFlight(.cpu0, 1);
    for (0..count) |index| try answer(&model, @intCast(1 + index), 7);
    var next = inFlight(.cpu0, 50);
    next.now = model.now;
    next.observe(.{ .response = .{ .id = 50, .result = .{ .err = @fromBackingInt(@intCast(0x0003)) } } });
    for (1..count) |index| try answer(&next, @intCast(50 + index), 8);
    try std.testing.expectEqualStrings("the session would not read the registers", next.note().?);
    try std.testing.expectEqual(@as(u32, 7), next.now.?.values[3]);
}

test "a load asks both cores again and forgets what came before" {
    var pair: shell_registers.Pair = .{};
    pair.cores[1].now = .{};
    pair.cores[1].before = .{};
    pair.reload();
    for (pair.cores) |model| {
        try std.testing.expect(model.want);
        try std.testing.expectEqual(@as(?shell_registers.Snapshot, null), model.before);
        try std.testing.expectEqualStrings("waiting for the registers", model.note().?);
    }
    try std.testing.expectEqual(proto.Core.cpu1, pair.of(.cpu1).core);
}

test "a batch in flight when a load lands publishes nothing, and a fresh one follows" {
    var model = inFlight(.cpu0, 1);
    model.reload();
    for (0..count) |index| try answer(&model, @intCast(1 + index), 7);
    try std.testing.expectEqual(@as(?shell_registers.Snapshot, null), model.now);
    try std.testing.expectEqual(@as(?shell_registers.Snapshot, null), model.before);
    try std.testing.expect(model.want);
    try std.testing.expect(!model.stale);
    try std.testing.expectEqualStrings("waiting for the registers", model.note().?);
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

test "a registers leaf draws its core's values, changes in amber, in place of its note" {
    const gpa = std.testing.allocator;
    var pair: shell_registers.Pair = .{};
    var before: shell_registers.Snapshot = .{};
    before.values[0] = 1;
    pair.cores[0].now = .{};
    pair.cores[0].before = before;
    var layout = try pane_layout.twoCore(gpa);
    defer layout.deinit();
    for (layout.nodes.items, 0..) |node, index| if (node.body == .leaf) {
        try layout.setKind(@intCast(index), .registers);
    };
    var solved = try frame.solve(&layout, gpa, 960, 640);
    defer solved.deinit(gpa);
    var pixels = try raster.Framebuffer.init(gpa, 960, 640);
    defer pixels.deinit(gpa);
    var list = draw_list.DrawList.init(gpa, 960, 640);
    defer list.deinit();
    const status: status_bar.Status = .{};
    var painter: panes.Panes = .{ .registers = &pair };
    try frame.draw(&list, dark, .{ .layout = &layout, .solved = &solved, .strip = status_capture.strip(&status, .closed), .width = 960, .height = 640, .painter = painter.painter() });
    raster.draw(&pixels, &list, font.atlas);
    var drawn: usize = 0;
    var waiting: usize = 0;
    for (solved.panes.items) |leaf| {
        const placed = layout.pane(leaf.index) orelse continue;
        const body = frame.bodyOf(leaf.area);
        if (placed.core == .cpu0) {
            drawn += 1;
            try std.testing.expect(holds(&pixels, body, dark.highlight));
        } else {
            waiting += 1;
            try std.testing.expect(!holds(&pixels, body, dark.highlight));
            try std.testing.expect(holds(&pixels, body, dark.muted));
        }
    }
    try std.testing.expect(drawn > 0 and waiting > 0);
}

test "a batch meeting a full pending table sends its other reads as slots free" {
    var wire: Wire = .{};
    try wire.open();
    defer wire.close();
    var held: [20]u32 = undefined;
    const pc: proto.ReadRegister = .{ .core = .cpu1, .register = shell_registers.wire[15] };
    for (&held) |*id| id.* = try wire.link.send(proto.ReadRegister, .read_register, pc);
    var model: Registers = .{ .core = .cpu0 };
    model.reload();
    model.attach(&wire.link);
    try std.testing.expect(wire.link.state == .connected);
    try std.testing.expectEqual(@as(usize, 12), model.left);
    try std.testing.expect(!model.refused);
    for (held) |id| _ = try wire.link.client.pending.take(id);
    model.attach(&wire.link);
    try std.testing.expectEqual(@as(usize, proto.pending_slots), model.next);
    for (model.asked[0..model.next]) |id| _ = try wire.link.client.pending.take(id.?);
    model.attach(&wire.link);
    try std.testing.expectEqual(count, model.left);
    try std.testing.expectEqual(count, model.next);
}

test "a CPU1 batch never asks VPR, and a CPU0 batch does" {
    var wire: Wire = .{};
    try wire.open();
    defer wire.close();
    const vpr = std.mem.indexOfScalar(proto.Register, &shell_registers.wire, .vpr).?;
    for ([_]proto.Core{ .cpu0, .cpu1 }) |core| {
        var model: Registers = .{ .core = core };
        model.reload();
        var done: usize = 0;
        while (true) {
            model.attach(&wire.link);
            for (model.asked[done..model.next]) |id| if (id) |taken| {
                _ = try wire.link.client.pending.take(taken);
            };
            done = model.next;
            if (model.next == count) break;
        }
        const mve = registers_pane.hasMve(core);
        try std.testing.expectEqual(mve, model.asked[vpr] != null);
        try std.testing.expectEqual(if (mve) count else count - 1, model.left);
    }
}

test "a press on a group header folds it, and a second unfolds it" {
    var model: Registers = .{ .core = .cpu0, .now = .{} };
    const body = draw_list.Rect{ .x = 10, .y = 20, .w = 600, .h = 300 };
    const header = registers_pane.headerRect(body, model.fold, 1).?;
    try std.testing.expect(model.toggle(body, header.x + 1, header.y + 1));
    try std.testing.expect(model.fold[1]);
    const cell = registers_pane.cellRect(body, model.fold, 0).?;
    try std.testing.expect(!model.toggle(body, cell.x + 1, cell.y + 1));
    try std.testing.expect(model.toggle(body, header.x + 1, header.y + 1));
    try std.testing.expect(!model.fold[1]);
}

test "a leaf with nothing published ignores header presses" {
    var model: Registers = .{ .core = .cpu1 };
    const body = draw_list.Rect{ .x = 0, .y = 0, .w = 600, .h = 300 };
    const header = registers_pane.headerRect(body, model.fold, 0).?;
    try std.testing.expect(!model.toggle(body, header.x + 1, header.y + 1));
    try std.testing.expect(!model.fold[0]);
}

test "a halt with no stop event makes both cores due for a read" {
    var pair: gui_app.shell.registers.Pair = .{};
    try std.testing.expect(!pair.cores[0].want and !pair.cores[1].want);
    pair.refresh();
    try std.testing.expect(pair.cores[0].want and pair.cores[1].want);
}
