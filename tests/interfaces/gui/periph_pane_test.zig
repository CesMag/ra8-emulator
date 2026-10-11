//! Covers ui/periph_pane.zig and periph_capture.zig (RA8EMU-819): the
//! layout at two sizes, block selection, a pane too small, the registers
//! of one block read through a real session, and the pinned golden frame.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Machine = ra8.session.stop_machine.Machine;
const zig_session = ra8.session.step_hook.zig.session;
const api = ra8.session.api;
const periph = ra8.chip.periph.registry;
const periph_list = ra8.session.periph_list;
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;
const dark = &gui_app.colors.palettes.dark;
const Theme = gui_app.colors.Theme;
const pane = gui_app.periph_pane;
const capture = gui_app.periph_capture;
const Rect = draw_list.Rect;

const wide: Rect = .{ .x = 0, .y = 0, .w = 320, .h = 240 };
const tall: Rect = .{ .x = 0, .y = 0, .w = 320, .h = 440 };
const tiny: Rect = .{ .x = 0, .y = 0, .w = 20, .h = 20 };
const GOLDEN: u64 = 10085532088711733549;

/// A RAM the session reads: every byte is a pure function of its address,
/// so the capture's overlapping word reads are checkable.
/// The Ram answers for the registry's periph window at `base` and, from
/// address 0, the vector table the reset reads.
const ram_base: u32 = 0x4000_0000;

/// Where `address` sits inside the Ram's bytes, or past their end.
fn ramAt(address: u32) u32 {
    if (address < ram_bytes_len) return address;
    return address - ram_base;
}

const ram_bytes_len: u32 = 512;

const Ram = struct {
    bytes: [512]u8 = @splat(0),

    fn view(self: *Ram) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }
    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        const at = ramAt(address);
        if (at >= ram_bytes_len or at + into.len > ram_bytes_len) return error.Unmapped;
        @memcpy(into, self.bytes[at..][0..into.len]);
    }
    fn write(ctx: *anyopaque, address: u32, bytes: []const u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        const at = ramAt(address);
        if (at >= ram_bytes_len or at + bytes.len > ram_bytes_len) return error.Unmapped;
        @memcpy(self.bytes[at..][0..bytes.len], bytes);
    }
};

/// The Ram's answer for byte `at`.
fn ramByte(at: usize) u8 {
    return @truncate(at * 7 + 3);
}

/// The little-endian word of `length` bytes at `address`.
fn ramWord(ram: *const Ram, address: u32, length: usize) u32 {
    var value: u32 = 0;
    for (0..length) |index| value |= @as(u32, ram.bytes[address + index]) << @intCast(8 * index);
    return value;
}

/// The length one register's read takes: its width, or a full word when
/// the model declares none.
fn readLength(width: u8) usize {
    return switch (width) {
        1 => 1,
        2 => 2,
        else => 4,
    };
}

fn nothing(_: *anyopaque, _: u32, _: u3) u32 {
    return 0;
}

fn nothingWrite(_: *anyopaque, _: u32, _: u3, _: u32) void {}

/// An RTC block the pane can list; its reads run through the Ram.
fn rtcBlock(base: u32) periph.Block {
    return .{
        .name = "RTC",
        .base = base,
        .size = 0x40,
        .context = @ptrFromInt(1),
        .readFn = nothing,
        .writeFn = nothingWrite,
    };
}

/// A snapshot with three blocks and the RTC model's registers.
fn sample() pane.Snapshot {
    var snap: pane.Snapshot = .{};
    const names = [_][]const u8{ "RTC", "AGT", "IWDT" };
    for (names, 0..) |name, index| {
        snap.blocks[index] = .{
            .name = name,
            .base = 0x4001_0000 + @as(u32, @intCast(index)) * 0x100,
            .size = 0x40,
        };
        snap.block_count += 1;
    }
    snap.selected = 0;
    for (periph_list.registers("RTC").?, 0..) |reg, index| {
        snap.regs[index] = .{ .name = reg.name, .offset = reg.offset, .width = reg.width };
        snap.values[index] = 0x1100_0000 + @as(u32, @intCast(index));
        snap.readable[index] = true;
        snap.reg_count += 1;
    }
    return snap;
}

test "the layout holds every register when tall and cuts them when short" {
    const snap = sample();
    try std.testing.expect(pane.rows(wide) > 0);
    try std.testing.expect(pane.rows(tall) >= snap.reg_count);
    try std.testing.expect(pane.blockRect(wide, &snap, 0) != null);
    try std.testing.expect(pane.regRect(wide, &snap, 0) != null);
    try std.testing.expect(pane.regRect(tall, &snap, snap.reg_count - 1) != null);
    // The wide area holds fewer rows than the 19 registers need.
    try std.testing.expect(pane.regRect(tall, &snap, snap.reg_count - 1) != null);
    try std.testing.expect(pane.regRect(wide, &snap, pane.rows(wide)) == null);
}

test "a pane too small draws nothing" {
    const snap = sample();
    try std.testing.expectEqual(@as(usize, 0), pane.rows(tiny));
    try std.testing.expect(pane.blockRect(tiny, &snap, 0) == null);
    try std.testing.expect(pane.regRect(tiny, &snap, 0) == null);
    var list = draw_list.DrawList.init(std.testing.allocator, @intCast(tiny.w), @intCast(tiny.h));
    defer list.deinit();
    try pane.draw(&list, dark, tiny, &snap, null);
    try std.testing.expectEqual(@as(usize, 0), list.commands.items.len);
}

test "a click on a block's row selects it, empty space does not" {
    const snap = sample();
    const rect = pane.blockRect(wide, &snap, 2).?;
    try std.testing.expectEqual(@as(?usize, 2), pane.hit(wide, &snap, rect.x + 2, rect.y + 2));
    try std.testing.expectEqual(@as(?usize, null), pane.hit(wide, &snap, wide.w - 2, 1));
}

test "a value differs from an earlier snapshot only when it moved" {
    var snap = sample();
    var before = snap;
    try std.testing.expect(!snap.changedAt(&before, 3));
    snap.values[3] += 1;
    try std.testing.expect(snap.changedAt(&before, 3));
    try std.testing.expect(!snap.changedAt(null, 3));
    // A register the old snapshot did not hold cannot compare.
    before.reg_count = 0;
    try std.testing.expect(!snap.changedAt(&before, 3));
}

test "capture reads one block's registers through the session" {
    var ram = Ram{};
    for (&ram.bytes, 0..) |*byte, at| byte.* = ramByte(at);
    @memcpy(ram.bytes[0..8], &[_]u8{ 0x40, 0, 0, 0, 0x09, 0, 0, 0 });
    var cpu: Cpu = .{ .bus = ram.view() };
    try cpu.reset(0);
    var machine = Machine{};
    const live: zig_session.ZigSession = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 100 };
    var session: api.Session = .{ .live = live };

    var bus_map = periph.Bus.init(std.testing.allocator);
    defer bus_map.deinit();
    try bus_map.add(rtcBlock(ram_base + 0x100));
    const snap = try capture.capture(&session, .cpu0, &bus_map, "RTC");

    const regs = periph_list.registers("RTC").?;
    try std.testing.expectEqual(@as(usize, 1), snap.block_count);
    try std.testing.expectEqual(@as(usize, 0), snap.selected);
    try std.testing.expectEqualStrings("RTC", snap.blocks[0].name);
    try std.testing.expectEqual(ram_base + 0x100, snap.blocks[0].base);
    try std.testing.expectEqual(regs.len, snap.reg_count);
    for (regs, 0..) |reg, index| {
        try std.testing.expectEqualStrings(reg.name, snap.regs[index].name);
        try std.testing.expectEqual(reg.offset, snap.regs[index].offset);
        try std.testing.expectEqual(reg.width, snap.regs[index].width);
        try std.testing.expect(snap.readable[index]);
        try std.testing.expectEqual(ramWord(&ram, 0x100 + reg.offset, readLength(reg.width)), snap.values[index]);
    }
}

test "a block no model pairs with lists no registers" {
    var ram = Ram{};
    var cpu: Cpu = .{ .bus = ram.view() };
    try cpu.reset(0);
    var machine = Machine{};
    const live: zig_session.ZigSession = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 100 };
    var session: api.Session = .{ .live = live };

    var bus_map = periph.Bus.init(std.testing.allocator);
    defer bus_map.deinit();
    try bus_map.add(rtcBlock(ram_base + 0x100));
    const snap = try capture.capture(&session, .cpu0, &bus_map, "OTHER");
    try std.testing.expectEqual(@as(usize, 1), snap.block_count);
    try std.testing.expectEqual(@as(usize, 0), snap.reg_count);
}

test "a read the bus refuses shows no value" {
    var ram = Ram{};
    var cpu: Cpu = .{ .bus = ram.view() };
    try cpu.reset(0);
    var machine = Machine{};
    const live: zig_session.ZigSession = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 100 };
    var session: api.Session = .{ .live = live };

    var bus_map = periph.Bus.init(std.testing.allocator);
    defer bus_map.deinit();
    try bus_map.add(rtcBlock(ram_base + 0x100 + 0x400));
    const snap = try capture.capture(&session, .cpu0, &bus_map, "RTC");
    const regs = periph_list.registers("RTC").?;
    try std.testing.expectEqual(regs.len, snap.reg_count);
    for (0..snap.reg_count) |index| {
        try std.testing.expect(!snap.readable[index]);
        try std.testing.expectEqual(@as(u32, 0), snap.values[index]);
    }
}

test "the pane with one register changed rasterises to the pinned golden frame" {
    var snap = sample();
    var before = snap;
    before.values[1] = 0;
    try std.testing.expectEqual(GOLDEN, try digest(dark, &snap, &before, "/tmp/periph819.ppm"));
}

fn digest(theme: *const Theme, now: *const pane.Snapshot, before: ?*const pane.Snapshot, path: [:0]const u8) !u64 {
    var list = draw_list.DrawList.init(std.testing.allocator, @intCast(wide.w), @intCast(wide.h));
    defer list.deinit();
    var frame = try raster.Framebuffer.init(std.testing.allocator, @intCast(wide.w), @intCast(wide.h));
    defer frame.deinit(std.testing.allocator);
    try pane.draw(&list, theme, wide, now, before);
    raster.draw(&frame, &list, font.atlas);
    {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(std.testing.allocator);
        try out.print(std.testing.allocator, "P6\n{d} {d}\n255\n", .{ frame.width, frame.height });
        for (frame.pixels) |p| try out.appendSlice(std.testing.allocator, &.{ p.r, p.g, p.b });
        const file = std.c.fopen(path, "wb") orelse return error.Open;
        _ = std.c.fwrite(out.items.ptr, 1, out.items.len, file);
        _ = std.c.fclose(file);
    }
    return std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(frame.pixels));
}
