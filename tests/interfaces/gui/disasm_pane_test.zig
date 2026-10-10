//! Covers src/interfaces/gui/ui/disasm_pane.zig (RA8EMU-743) and the
//! capture file that fills it, src/interfaces/gui/disasm_capture.zig
//! (RA8EMU-1079): the columns line up, a
//! corpus-like run decodes forward through a real session (a wide bl takes
//! four bytes), unreadable and straddling reads take two bytes each, the pc
//! band and the breakpoint square land only on their rows, a pane too narrow
//! draws nothing, a session capture rasterises to a pinned golden frame, and
//! decodeRead decodes the same run out of bytes read over the link.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");

const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Machine = ra8.session.stop_machine.Machine;
const zig_session = ra8.session.step_hook.zig_session;
const api = ra8.session.session_api;
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;
const pane = gui_app.disasm_pane;
const capture = gui_app.disasm_capture;

const Rect = draw_list.Rect;
/// Room for 24 characters of text and eight rows.
const area = Rect{ .x = 0, .y = 0, .w = 2 * pane.pad + 2 + @as(i32, @intCast(font.textWidth(pane.text_at + 24))), .h = 2 * pane.pad + 8 * pane.row_h };

/// push {r4, lr}; movs r0, #1; adds r0, r0, r1; bl; bx lr; pop {r4, pc}; nop
const code = [_]u16{ 0xB510, 0x2001, 0x1840, 0xF000, 0xF802, 0x4770, 0xBD10, 0xBF00 };
const code_at: u32 = 0x20;
const pc: u32 = 0x26;
const break_at: u32 = 0x2C;

/// A RAM image holding a vector table (initial sp 0x40, reset at 0x08) and
/// `code` at 0x20; everything past its 256 bytes is unmapped.
const Ram = struct {
    bytes: [256]u8 = @splat(0),

    fn init() Ram {
        var memory: Ram = .{};
        @memcpy(memory.bytes[0..8], &[_]u8{ 0x40, 0, 0, 0, 0x09, 0, 0, 0 });
        for (code, 0..) |half, index| std.mem.writeInt(u16, memory.bytes[code_at + 2 * index ..][0..2], half, .little);
        return memory;
    }

    fn view(self: *Ram) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        if (address + into.len > self.bytes.len) return error.Unmapped;
        @memcpy(into, self.bytes[address..][0..into.len]);
    }

    fn write(ctx: *anyopaque, address: u32, bytes: []const u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        if (address + bytes.len > self.bytes.len) return error.Unmapped;
        @memcpy(self.bytes[address..][0..bytes.len], bytes);
    }
};

/// Two cores, each on its own Ram, behind one session.
const Rig = struct {
    memory0: Ram,
    memory1: Ram,
    cpu0: Cpu,
    cpu1: Cpu,
    machine0: Machine,
    machine1: Machine,
    session: api.Session,

    fn init(self: *Rig) !void {
        self.memory0 = Ram.init();
        self.memory1 = Ram.init();
        self.cpu0 = .{ .bus = self.memory0.view() };
        self.cpu1 = .{ .bus = self.memory1.view() };
        try self.cpu0.reset(0);
        try self.cpu1.reset(0);
        self.machine0 = .{};
        self.machine1 = .{};
        var live: zig_session.ZigSession = .{ .core = .{ .cpu = &self.cpu0 }, .machine = &self.machine0, .budget = 100 };
        live.other = .{ .core = .{ .cpu = &self.cpu1 }, .machine = &self.machine1, .budget = 100, .index = 1 };
        self.session = .{ .live = live };
    }

    fn snapshot(self: *Rig) !pane.Snapshot {
        try self.session.setRegister(.cpu0, .pc, pc);
        return capture.capture(&self.session, .cpu0, code_at, 8);
    }
};

const Scene = struct {
    list: draw_list.DrawList,
    frame: raster.Framebuffer,

    fn init() !Scene {
        const w: u32 = @intCast(area.w);
        const h: u32 = @intCast(area.h);
        return .{ .list = draw_list.DrawList.init(std.testing.allocator, w, h), .frame = try raster.Framebuffer.init(std.testing.allocator, w, h) };
    }

    fn deinit(self: *Scene) void {
        self.list.deinit();
        self.frame.deinit(std.testing.allocator);
    }

    fn render(self: *Scene, snapshot: *const pane.Snapshot) !void {
        try pane.draw(&self.list, area, snapshot, &.{break_at});
        raster.draw(&self.frame, &self.list, font.atlas);
    }

    fn digest(self: *const Scene) u64 {
        return std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(self.frame.pixels));
    }

    fn at(self: *const Scene, x: i32, y: i32) draw_list.Color {
        return self.frame.at(@intCast(x), @intCast(y));
    }
};

test "the gutter, address, halfwords and text columns line up" {
    try std.testing.expectEqual(@as(usize, 2), pane.address_at);
    try std.testing.expectEqual(@as(usize, 12), pane.bytes_at);
    try std.testing.expectEqual(@as(usize, 23), pane.text_at);
    try std.testing.expectEqual(@as(usize, 8), pane.rows(area));
    try std.testing.expectEqual(pane.pad + 3 * pane.row_h, pane.rowRect(area, 3).y);
}

test "a corpus-like run decodes forward and a wide bl takes four bytes" {
    var rig: Rig = undefined;
    try rig.init();
    const snapshot = try rig.snapshot();
    try std.testing.expectEqual(pc, snapshot.pc);
    const sizes = [_]u8{ 2, 2, 2, 4, 2, 2, 2, 2 };
    const starts = [_][]const u8{ "push", "movs", "adds", "bl", "bx", "pop", "nop" };
    var address = code_at;
    for (snapshot.lines[0..8], 0..) |*line, index| {
        try std.testing.expectEqual(address, line.address);
        try std.testing.expectEqual(sizes[index], line.size);
        try std.testing.expect(line.decoded);
        if (index < starts.len) try std.testing.expect(std.mem.startsWith(u8, line.text(), starts[index]));
        address += line.size;
    }
}

test "unreadable and straddling instructions take two bytes each" {
    var rig: Rig = undefined;
    try rig.init();
    try rig.session.write(.cpu0, 0xFE, &.{ 0x00, 0xF0 });
    const snapshot = try capture.capture(&rig.session, .cpu0, 0xFC, 3);
    try std.testing.expectEqual(@as(u8, 2), snapshot.lines[0].size);
    try std.testing.expectEqual(@as(u32, 0xFE), snapshot.lines[1].address);
    try std.testing.expectEqual(@as(u8, 0), snapshot.lines[1].size);
    try std.testing.expect(!snapshot.lines[1].decoded);
    try std.testing.expectEqual(@as(u32, 0x100), snapshot.lines[2].address);
    try std.testing.expectEqual(@as(u8, 0), snapshot.lines[2].size);
}

test "the pc band and the breakpoint square land only on their rows" {
    var rig: Rig = undefined;
    try rig.init();
    const snapshot = try rig.snapshot();
    var scene = try Scene.init();
    defer scene.deinit();
    try scene.render(&snapshot);
    for (0..8) |row| {
        const band = pane.rowRect(area, row);
        const edge = scene.at(area.w - 1, band.y + 1);
        const expected_edge = if (row == 3) pane.pc_band else pane.background;
        try std.testing.expect(std.meta.eql(expected_edge, edge));
        const mark = pane.markRect(area, row);
        const centre = scene.at(mark.x + 1, mark.y + 1);
        try std.testing.expectEqual(row == 5, std.meta.eql(pane.break_mark, centre));
    }
}

test "a pane too narrow draws nothing" {
    var rig: Rig = undefined;
    try rig.init();
    const snapshot = try rig.snapshot();
    var list = draw_list.DrawList.init(std.testing.allocator, 400, 200);
    defer list.deinit();
    try pane.draw(&list, .{ .x = 0, .y = 0, .w = pane.min_w - 1, .h = 200 }, &snapshot, &.{});
    try std.testing.expectEqual(@as(usize, 0), list.commands.items.len);
}

test "a session capture rasterises to the pinned golden frame" {
    var rig: Rig = undefined;
    try rig.init();
    const snapshot = try rig.snapshot();
    var scene = try Scene.init();
    defer scene.deinit();
    try scene.render(&snapshot);
    try std.testing.expectEqual(@as(u64, 7011153241417841614), scene.digest());
}

/// Bytes as the shell reads them over the link, with which came back.
const Read = struct { bytes: [2 * code.len]u8, readable: [2 * code.len]bool };

/// `code` as read from `code_at`, every byte readable.
fn readCode() Read {
    var read: Read = .{ .bytes = undefined, .readable = @splat(true) };
    for (code, 0..) |half, index| std.mem.writeInt(u16, read.bytes[2 * index ..][0..2], half, .little);
    return read;
}

test "decodeRead decodes forward from pc out of bytes read from a row base" {
    const read = readCode();
    const snapshot = capture.decodeRead(pc, code_at, &read.bytes, &read.readable, 4);
    try std.testing.expectEqual(pc, snapshot.pc);
    try std.testing.expectEqual(@as(usize, 4), snapshot.count);
    try std.testing.expectEqual(@as(u8, 4), snapshot.lines[0].size);
    try std.testing.expect(snapshot.lines[0].decoded);
    const after = [_]u32{ 0x2A, 0x2C, 0x2E };
    for (after, snapshot.lines[1..4]) |address, line| {
        try std.testing.expectEqual(address, line.address);
        try std.testing.expectEqual(@as(u8, 2), line.size);
    }
}

test "decodeRead marks a halfword not read, or past the read, unreadable" {
    var read = readCode();
    read.readable[0x2A - code_at + 1] = false;
    const snapshot = capture.decodeRead(pc, code_at, &read.bytes, &read.readable, 6);
    try std.testing.expectEqual(@as(u8, 0), snapshot.lines[1].size);
    try std.testing.expectEqual(@as(u32, 0x2C), snapshot.lines[2].address);
    try std.testing.expect(snapshot.lines[2].decoded);
    try std.testing.expectEqual(@as(u32, 0x30), snapshot.lines[4].address);
    try std.testing.expectEqual(@as(u8, 0), snapshot.lines[4].size);
    const before = capture.decodeRead(code_at - 2, code_at, &read.bytes, &read.readable, 1);
    try std.testing.expectEqual(@as(u8, 0), before.lines[0].size);
}
