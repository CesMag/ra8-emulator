//! Host tests for the shell's memory leaf (RA8EMU-821): it follows each
//! core's freshly published registers from the row holding SP, a batch
//! asks one read per row only once due, its last answer publishes it with
//! refused rows unreadable, a core the session has not attached keeps the
//! last values with a note, a batch sent before a load is dropped, and the
//! memory leaf draws in place of its note. A code pair follows PC exactly,
//! and a disassembly leaf decodes from it with the pc band.
const std = @import("std");
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
const memory_pane = gui_app.memory_pane;
const disasm_pane = gui_app.disasm_pane;
const registers_pane = gui_app.registers_pane;
const registers_capture = gui_app.registers_capture;
const shell_registers = gui_app.shell_registers;
const shell_memory = gui_app.shell_memory;
const Memory = shell_memory.Memory;
const Stdio = ra8.rpc.stdio_transport.Stdio;
const session_link = gui_app.session_link;
const Env = proto.Client.Env;

const rows = shell_memory.rows;
const per_row = memory_pane.per_row;

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

/// A batch in flight from `base` with ids `first`, `first + 1`, ...
fn inFlight(core: proto.Core, base: u32, first: u32) Memory {
    var model: Memory = .{ .core = core, .left = rows, .gathered = .{ .base = base, .count = rows } };
    for (&model.asked, 0..) |*asked, row| asked.* = first + @as(u32, @intCast(row));
    return model;
}

fn answer(model: *Memory, id: u32, fill: u8) !void {
    var bytes: [64]u8 = undefined;
    const row: [per_row]u8 = @splat(fill);
    const payload = try proto.encode(proto.Memory, .{ .bytes = &row }, &bytes);
    model.observe(.{ .response = .{ .id = id, .result = .{ .ok = payload } } });
}

fn refuse(model: *Memory, id: u32, code: u16) void {
    model.observe(.{ .response = .{ .id = id, .result = .{ .err = @fromBackingInt(code) } } });
}

/// A registers pair whose `core` has published a batch with `which` at
/// `value`.
fn published(core: usize, which: shell_registers.Register, value: u32) shell_registers.Pair {
    var pair: shell_registers.Pair = .{};
    var snapshot: shell_registers.Snapshot = .{};
    for (registers_capture.shown, 0..) |shown, index| {
        if (shown == which) snapshot.values[index] = value;
    }
    pair.cores[core].now = snapshot;
    pair.cores[core].serial = 1;
    return pair;
}

test "memory follows a core's fresh registers from the row holding SP, once" {
    var memory: shell_memory.Pair = .{};
    const registers = published(1, .sp, 0x2200_0F3C);
    memory.follow(&registers);
    try std.testing.expect(!memory.cores[0].want);
    try std.testing.expect(memory.cores[1].want);
    try std.testing.expectEqual(@as(u32, 0x2200_0F3C), memory.cores[1].address);
    memory.cores[1].want = false;
    memory.follow(&registers);
    try std.testing.expect(!memory.cores[1].want);
}

test "a batch asks one read per row, and only once due" {
    var wire: Wire = .{};
    try wire.open();
    defer wire.close();
    var model: Memory = .{ .core = .cpu0 };
    model.attach(&wire.link);
    try std.testing.expectEqual(@as(usize, 0), model.left);
    model.follow(0x2000_0100, 1);
    model.attach(&wire.link);
    try std.testing.expectEqual(rows, model.left);
    try std.testing.expectEqual(@as(u32, 0x2000_0100), model.gathered.base);
    try std.testing.expectEqual(@as(u32, 0x2000_0110), model.gathered.rowAddress(1));
    const first = model.asked[0];
    model.follow(0x2000_0200, 2);
    model.attach(&wire.link);
    try std.testing.expectEqual(first, model.asked[0]);
    try std.testing.expect(model.want);
}

test "a code pair follows PC, reads from its row and keeps the exact address" {
    var wire: Wire = .{};
    try wire.open();
    defer wire.close();
    var code: shell_memory.Pair = .{ .follows = .pc };
    const registers = published(0, .pc, 0x0000_0126);
    code.follow(&registers);
    const model = &code.cores[0];
    try std.testing.expectEqual(@as(u32, 0x0000_0126), model.address);
    code.attach(&wire.link);
    try std.testing.expectEqual(@as(u32, 0x0000_0120), model.gathered.base);
    for (model.asked) |asked| try answer(model, asked.?, 0x00);
    try std.testing.expectEqual(@as(u32, 0x0000_0126), model.from);
    try std.testing.expectEqual(@as(u32, 0x0000_0120), model.now.?.base);
}

test "the last answer publishes the batch, with a refused row unreadable" {
    var model = inFlight(.cpu0, 0x2000_0000, 1);
    refuse(&model, 1, 0x0100);
    for (1..rows) |row| {
        try std.testing.expectEqual(@as(?shell_memory.Snapshot, null), model.now);
        try answer(&model, @intCast(1 + row), 0xAB);
    }
    const now = model.now.?;
    try std.testing.expect(!now.readable[0]);
    try std.testing.expect(now.readable[per_row]);
    try std.testing.expectEqual(@as(u8, 0xAB), now.bytes[per_row]);
    try std.testing.expectEqual(@as(?[]const u8, null), model.note());
}

test "an answer to another ask is ignored" {
    var model = inFlight(.cpu1, 0, 10);
    try answer(&model, 9, 1);
    try answer(&model, 10 + rows, 1);
    try std.testing.expectEqual(rows, model.left);
}

test "a core the session has not attached keeps the last values with a note" {
    var model = inFlight(.cpu0, 0, 1);
    for (0..rows) |row| try answer(&model, @intCast(1 + row), 7);
    var next = inFlight(.cpu0, 0, 50);
    next.now = model.now;
    refuse(&next, 50, 0x0101);
    for (1..rows) |row| try answer(&next, @intCast(50 + row), 8);
    try std.testing.expectEqualStrings("the session would not read memory", next.note().?);
    try std.testing.expectEqual(@as(u8, 7), next.now.?.bytes[3]);
}

test "a batch in flight when a load lands publishes nothing" {
    var model = inFlight(.cpu0, 0, 1);
    model.reload();
    for (0..rows) |row| try answer(&model, @intCast(1 + row), 7);
    try std.testing.expectEqual(@as(?shell_memory.Snapshot, null), model.now);
    try std.testing.expect(!model.want);
    try std.testing.expect(!model.stale);
    try std.testing.expectEqualStrings("waiting for memory", model.note().?);
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

test "a memory leaf draws its core's rows in place of its note" {
    const gpa = std.testing.allocator;
    var pair: shell_memory.Pair = .{};
    var snapshot: shell_memory.Snapshot = .{ .base = 0x2000_0000, .count = rows };
    @memset(&snapshot.readable, true);
    pair.cores[0].now = snapshot;
    var layout = try pane_layout.twoCore(gpa);
    defer layout.deinit();
    for (layout.nodes.items, 0..) |node, index| if (node.body == .leaf) {
        try layout.setKind(@intCast(index), .memory);
    };
    var solved = try frame.solve(&layout, gpa, 2000, 320);
    defer solved.deinit(gpa);
    var pixels = try raster.Framebuffer.init(gpa, 2000, 320);
    defer pixels.deinit(gpa);
    var list = draw_list.DrawList.init(gpa, 2000, 320);
    defer list.deinit();
    const status: status_bar.Status = .{};
    var painter: panes.Panes = .{ .memory = &pair };
    try frame.draw(&list, .{ .layout = &layout, .solved = &solved, .strip = status_capture.strip(&status, .closed), .width = 2000, .height = 320, .painter = painter.painter() });
    raster.draw(&pixels, &list, font.atlas);
    var drawn: usize = 0;
    var waiting: usize = 0;
    for (solved.panes.items) |leaf| {
        const placed = layout.pane(leaf.index) orelse continue;
        const body = frame.bodyOf(leaf.area);
        if (placed.core == .cpu0) {
            drawn += 1;
            try std.testing.expect(holds(&pixels, body, memory_pane.ink));
        } else {
            waiting += 1;
            try std.testing.expect(!holds(&pixels, body, memory_pane.ink));
            try std.testing.expect(holds(&pixels, body, frame.muted));
        }
    }
    try std.testing.expect(drawn > 0 and waiting > 0);
}

test "a disassembly leaf decodes from its core's PC with the pc band" {
    const gpa = std.testing.allocator;
    var code: shell_memory.Pair = .{ .follows = .pc };
    var read: shell_memory.Snapshot = .{ .base = 0x100, .count = rows };
    @memset(&read.readable, true);
    for (0..rows * per_row / 2) |half| std.mem.writeInt(u16, read.bytes[2 * half ..][0..2], 0xBF00, .little);
    code.cores[0].now = read;
    code.cores[0].from = 0x104;
    var layout = try pane_layout.twoCore(gpa);
    defer layout.deinit();
    for (layout.nodes.items, 0..) |node, index| if (node.body == .leaf) {
        try layout.setKind(@intCast(index), .disasm);
    };
    var solved = try frame.solve(&layout, gpa, 2000, 320);
    defer solved.deinit(gpa);
    var pixels = try raster.Framebuffer.init(gpa, 2000, 320);
    defer pixels.deinit(gpa);
    var list = draw_list.DrawList.init(gpa, 2000, 320);
    defer list.deinit();
    const status: status_bar.Status = .{};
    var painter: panes.Panes = .{ .code = &code };
    try frame.draw(&list, .{ .layout = &layout, .solved = &solved, .strip = status_capture.strip(&status, .closed), .width = 2000, .height = 320, .painter = painter.painter() });
    raster.draw(&pixels, &list, font.atlas);
    var drawn: usize = 0;
    var waiting: usize = 0;
    for (solved.panes.items) |leaf| {
        const placed = layout.pane(leaf.index) orelse continue;
        const body = frame.bodyOf(leaf.area);
        if (placed.core == .cpu0) {
            drawn += 1;
            try std.testing.expect(holds(&pixels, body, disasm_pane.pc_band));
        } else {
            waiting += 1;
            try std.testing.expect(!holds(&pixels, body, disasm_pane.pc_band));
            try std.testing.expect(holds(&pixels, body, frame.muted));
        }
    }
    try std.testing.expect(drawn > 0 and waiting > 0);
}

test "a batch meeting a full pending table sends its other rows as slots free" {
    var wire: Wire = .{};
    try wire.open();
    defer wire.close();
    var held: [20]u32 = undefined;
    const pc: proto.ReadRegister = .{ .core = .cpu0, .register = shell_registers.wire[15] };
    for (&held) |*id| id.* = try wire.link.send(proto.ReadRegister, .read_register, pc);
    var model: Memory = .{ .core = .cpu0 };
    model.follow(0x2000_0100, 1);
    model.attach(&wire.link);
    try std.testing.expect(wire.link.state == .connected);
    try std.testing.expectEqual(@as(usize, 12), model.left);
    try std.testing.expectEqual(@as(usize, 12), model.next);
    try std.testing.expectEqualStrings("waiting for memory", model.note().?);
    for (held) |id| _ = try wire.link.client.pending.take(id);
    model.attach(&wire.link);
    try std.testing.expectEqual(rows, model.left);
    try std.testing.expectEqual(rows, model.next);
}
