//! Host test for the shell's core leaves against a live session
//! (RA8EMU-821): a spawned `serve --stdio` steps cpu0 twice, and the
//! registers, memory and disassembly leaves each draw its live values, with
//! the registers the step changed marked; and the FPU group shows the bits
//! fp_basic computes, marked on the step that wrote them (RA8EMU-944); and
//! on the Helium DSP corpus the MVE group draws, with the q lane a step
//! wrote marked (RA8EMU-947).
const std = @import("std");
const dark = &@import("gui_app").colors.palettes.dark;
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const status_capture = gui_app.status.capture;
const test_paths = @import("test_paths");
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
const memory_pane = gui_app.memory_pane;
const disasm_pane = gui_app.disasm_pane;
const shell_registers = gui_app.shell.registers;
const shell_memory = gui_app.shell.memory;
const session_link = gui_app.session_link;
const Link = session_link.Link;
const Env = proto.Client.Env;

const image_path = "tests/fixtures/fpu/fp_basic.elf";
const dsp_path = "tests/fixtures/fpu/dsp.elf";
const width = 2000;
const height = 960;

/// The three core leaves, fed in the shell's own order (shell_loop
/// observeCore): registers take the arrival, then memory and code follow.
const Leaves = struct {
    registers: shell_registers.Pair = .{},
    memory: shell_memory.Pair = .{},
    code: shell_memory.Pair = .{ .follows = .pc },

    fn attach(self: *Leaves, link: *Link) void {
        self.registers.attach(link);
        self.memory.attach(link);
        self.code.attach(link);
    }

    fn observe(self: *Leaves, arrival: session_link.Arrival) void {
        self.registers.observe(arrival);
        for ([_]*shell_memory.Pair{ &self.memory, &self.code }) |memory| {
            memory.observe(arrival);
            memory.follow(&self.registers);
        }
    }

    /// cpu0 has published registers batch `serial`, and memory and code
    /// have published the batch that followed it.
    fn settled(self: *const Leaves, serial: u32) bool {
        const registers = &self.registers.cores[0];
        if (registers.serial != serial or registers.left != 0 or registers.want) return false;
        for ([_]*const shell_memory.Pair{ &self.memory, &self.code }) |memory| {
            const core = &memory.cores[0];
            if (core.seen != serial or core.left != 0 or core.want or core.now == null) return false;
        }
        return true;
    }
};

fn nowMs() i64 {
    return std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds();
}

/// Pump `link` into `leaves` for up to ten seconds: until it connects when
/// `serial` is null, else until cpu0 settles on registers batch `serial`.
fn pumpUntil(link: *Link, leaves: *Leaves, serial: ?u32) !void {
    const deadline = nowMs() + 10_000;
    while (nowMs() < deadline) {
        if (link.state != .connecting and link.state != .connected) {
            return error.LinkDown;
        }
        leaves.attach(link);
        if (link.pump()) |arrival| {
            leaves.observe(arrival);
            continue;
        }
        const done = if (serial) |want| leaves.settled(want) else link.state == .connected;
        if (done) return;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.Timeout;
}

/// Step cpu0 once and wait for every leaf to follow the stop.
fn step(link: *Link, leaves: *Leaves) !void {
    const serial = leaves.registers.cores[0].serial +% 1;
    _ = try link.send(proto.Run, .run, .{ .core = .cpu0, .mode = .step, .budget = 0 });
    try pumpUntil(link, leaves, serial);
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

/// Every leaf shows `kind`: cpu0's leaves hold `color`, cpu1's (never
/// stopped) hold only their muted note.
fn expectFrame(gpa: std.mem.Allocator, leaves: *const Leaves, state: session_link.State, kind: pane_layout.Kind, color: draw_list.Color) !void {
    var layout = try pane_layout.twoCore(gpa);
    defer layout.deinit();
    for (layout.nodes.items, 0..) |node, index| if (node.body == .leaf) {
        try layout.setKind(@intCast(index), kind);
    };
    var solved = try frame.solve(&layout, gpa, width, height);
    defer solved.deinit(gpa);
    var pixels = try raster.Framebuffer.init(gpa, width, height);
    defer pixels.deinit(gpa);
    var list = draw_list.DrawList.init(gpa, width, height);
    defer list.deinit();
    const status: status_bar.Status = .{};
    var painter: panes.Panes = .{ .registers = &leaves.registers, .memory = &leaves.memory, .code = &leaves.code };
    try frame.draw(&list, dark, .{ .layout = &layout, .solved = &solved, .strip = status_capture.strip(&status, state), .width = width, .height = height, .painter = painter.painter() });
    raster.draw(&pixels, &list, font.atlas);
    var drawn: usize = 0;
    var waiting: usize = 0;
    for (solved.panes.items) |leaf| {
        const placed = layout.pane(leaf.index) orelse continue;
        const body = frame.bodyOf(leaf.area);
        if (placed.core == .cpu0) {
            drawn += 1;
            try std.testing.expect(holds(&pixels, body, color));
        } else {
            waiting += 1;
            try std.testing.expect(!holds(&pixels, body, color));
            try std.testing.expect(holds(&pixels, body, dark.muted));
        }
    }
    try std.testing.expect(drawn > 0 and waiting > 0);
}

test "a spawned serve --stdio feeds live registers, memory and disassembly leaves after a step" {
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
    var leaves: Leaves = .{};
    try pumpUntil(&link, &leaves, null);
    // Stops reach only subscribers; the shell's status bar subscribes for it.
    _ = try link.send(proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .stop });

    try step(&link, &leaves);
    const first_pc = leaves.registers.cores[0].value(.pc).?;
    try step(&link, &leaves);
    const registers = &leaves.registers.cores[0];
    try std.testing.expect(registers.before != null);
    try std.testing.expect(registers.value(.pc).? != first_pc);
    try std.testing.expectEqual(registers.value(.sp).?, leaves.memory.cores[0].from);
    try std.testing.expectEqual(registers.value(.pc).?, leaves.code.cores[0].from);
    try std.testing.expect(leaves.registers.cores[1].now == null);

    // fp_basic's second step moves only the pc, which keeps its own mark.
    try expectFrame(gpa, &leaves, link.state, .registers, dark.pc_cyan);
    try expectFrame(gpa, &leaves, link.state, .memory, dark.ink);
    try expectFrame(gpa, &leaves, link.state, .disasm, dark.pc_band_bg);

    local.end();
    while (link.state == .connected) {
        if (link.pump() == null) try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try local.reap());
}

/// Where `bits` sits among the S registers of `snapshot`, if anywhere.
fn singleHolding(snapshot: registers_pane.Snapshot, bits: u32) ?usize {
    const s0 = std.mem.indexOfScalar(shell_registers.Register, &registers_capture.shown, .s0).?;
    for (s0..s0 + 32) |index| if (snapshot.values[index] == bits) return index;
    return null;
}

test "the fpu group shows the sum fp_basic computes, marked on the step that wrote it" {
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
    var leaves: Leaves = .{};
    try pumpUntil(&link, &leaves, null);
    _ = try link.send(proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .stop });

    // fp_basic's first single-precision result: 1.0 + 3.0 = 4.0.
    const sum: u32 = 0x4080_0000;
    var steps: usize = 0;
    const at = while (steps < 2000) : (steps += 1) {
        try step(&link, &leaves);
        if (singleHolding(leaves.registers.cores[0].now.?, sum)) |index| break index;
    } else return error.SumNeverShown;
    const registers = &leaves.registers.cores[0];
    try std.testing.expect(registers.now.?.changedAt(registers.before.?, at));

    local.end();
    while (link.state == .connected) {
        if (link.pump() == null) try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try local.reap());
}

/// The first q lane `registers` marks changed, if any.
fn laneChanged(registers: *const shell_registers.Registers) ?usize {
    const now = registers.now orelse return null;
    const before = registers.before orelse return null;
    for (registers_capture.shown.len..registers_pane.cells) |cell| {
        if (now.changedAt(before, registers_pane.valueIndex(cell))) return cell;
    }
    return null;
}

test "the MVE group draws on cpu0 and marks the q lane a Helium step wrote" {
    const gpa = std.testing.allocator;
    var local: session_link.Local = undefined;
    try local.spawn(std.testing.io, test_paths.emulator, dsp_path);
    errdefer local.child.kill(std.testing.io);
    const rx = try gpa.alloc(u8, 2 * Env.max_frame);
    defer gpa.free(rx);
    const tx = try gpa.alloc(u8, Env.max_frame);
    defer gpa.free(tx);
    var link: Link = undefined;
    link.open(local.transport(), rx, tx);
    var leaves: Leaves = .{};
    try pumpUntil(&link, &leaves, null);
    _ = try link.send(proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .stop });

    var steps: usize = 0;
    const cell = while (steps < 3000) : (steps += 1) {
        try step(&link, &leaves);
        if (laneChanged(&leaves.registers.cores[0])) |hit| break hit;
    } else return error.LaneNeverChanged;
    const registers = &leaves.registers.cores[0];
    try std.testing.expect(registers.now.?.mve);
    try std.testing.expect(cell >= registers_capture.shown.len and cell < registers_pane.cells);
    try expectFrame(gpa, &leaves, link.state, .registers, dark.highlight);

    local.end();
    while (link.state == .connected) {
        if (link.pump() == null) try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try local.reap());
}
