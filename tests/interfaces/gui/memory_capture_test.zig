//! Covers src/interfaces/gui/memory_capture.zig (RA8EMU-1078): a capture
//! from a real session rasterises to the memory pane's pinned golden frame,
//! and capture reads each core across the end of mapped memory.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");

const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Machine = ra8.session.stop_machine.Machine;
const zig_session = ra8.session.step_hook.zig_session;
const api = ra8.session.api;
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;
const pane = gui_app.memory_pane;
const capture = gui_app.memory_capture;

/// Exactly one row wide and four rows deep, as in the pane's own test.
const area = draw_list.Rect{ .x = 0, .y = 0, .w = pane.min_w, .h = 2 * pane.pad + 4 * pane.row_h };

/// The pane's frame for `snapshot`, hashed.
fn digest(snapshot: *const pane.Snapshot) !u64 {
    const w: u32 = @intCast(area.w);
    const h: u32 = @intCast(area.h);
    var list = draw_list.DrawList.init(std.testing.allocator, w, h);
    defer list.deinit();
    var frame = try raster.Framebuffer.init(std.testing.allocator, w, h);
    defer frame.deinit(std.testing.allocator);
    try pane.draw(&list, area, snapshot);
    raster.draw(&frame, &list, font.atlas);
    return std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(frame.pixels));
}

/// A RAM image holding a vector table (initial sp 0x40, reset at 0x08);
/// everything past its 256 bytes is unmapped.
const Ram = struct {
    bytes: [256]u8 = @splat(0),

    fn init() Ram {
        var memory: Ram = .{};
        @memcpy(memory.bytes[0..8], &[_]u8{ 0x40, 0, 0, 0, 0x09, 0, 0, 0 });
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
};

test "a capture from a session's core rasterises to the pinned golden frame" {
    var rig: Rig = undefined;
    try rig.init();
    try rig.session.write(.cpu1, 0xE0, "RA8 memory pane!");
    const snapshot = try capture.capture(&rig.session, .cpu1, 0xE8, 4);
    try std.testing.expectEqual(@as(u64, 16333086650271298263), try digest(&snapshot));
}

test "capture reads each core through the session and marks unmapped bytes" {
    var rig: Rig = undefined;
    try rig.init();
    const session = &rig.session;
    try session.write(.cpu0, 0xE0, "RA8 memory pane!");
    try session.write(.cpu1, 0xE0, "second core here");
    const zero = try capture.capture(session, .cpu0, 0xE0, 3);
    const one = try capture.capture(session, .cpu1, 0xE0, 1);
    try std.testing.expectEqualStrings("RA8 memory pane!", zero.bytes[0..16]);
    try std.testing.expectEqualStrings("second core here", one.bytes[0..16]);
    for (zero.readable[0..32]) |readable| try std.testing.expect(readable);
    for (zero.readable[32..48]) |readable| try std.testing.expect(!readable);
    const straddle = try capture.capture(session, .cpu0, 0xF8, 2);
    for (straddle.readable[0..8]) |readable| try std.testing.expect(readable);
    for (straddle.readable[8..32]) |readable| try std.testing.expect(!readable);
    try std.testing.expectEqual(@as(u32, 0x108), straddle.rowAddress(1));
    const capped = try capture.capture(session, .cpu0, 0, pane.max_rows + 5);
    try std.testing.expectEqual(pane.max_rows, capped.count);
}
