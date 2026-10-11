//! Covers src/interfaces/gui/ui/source_pane.zig (RA8EMU-745) and the
//! capture file that fills it, src/interfaces/gui/source_capture.zig
//! (RA8EMU-1080), on the PACBTI fixture, whose
//! line table names pacbti_smoke.S beside it: the rows centre on pc's line,
//! an address with no line and a missing file each say so, a gutter click
//! sets and then clears a real breakpoint, a pane too narrow draws nothing,
//! and the current line with a mark rasterises to a pinned golden frame.
const std = @import("std");
const dark = &@import("gui_app").colors.palettes.dark;
const light = &@import("gui_app").colors.palettes.light;
const ra8 = @import("ra8");
const gui_app = @import("gui_app");

const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Machine = ra8.session.stop_machine.Machine;
const zig_session = ra8.session.step_hook.zig.session;
const api = ra8.session.api;
const elf = ra8.board.image.elf;
const dwarf_line = ra8.session.dwarf.line;
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;
const pane = gui_app.source_pane;
const capture = gui_app.source_capture;

const Rect = draw_list.Rect;
/// Room for 40 characters of text and twelve rows.
const area = Rect{ .x = 0, .y = 0, .w = 2 * pane.pad + 2 + @as(i32, @intCast(font.textWidth(pane.text_at + 40))), .h = 2 * pane.pad + 12 * pane.row_h };

const image_bytes = @embedFile("../../fixtures/pacbti/pacbti_smoke.elf");
const source_dir = "tests/fixtures/pacbti";
/// main's first instruction, `pacbti r12, lr, sp` on line 18.
const main_pc: u32 = 0x0200_0024;
/// Rows 12 through 23 show, so line 18 is row 6 and line 22 is row 10.
const current_row: usize = 6;
const mark_line: u32 = 22;
const mark_row: usize = 10;

fn image() !elf.Image {
    return elf.Image.init(image_bytes);
}

fn sections() dwarf_line.Sections {
    return dwarf_line.ofImage(image() catch unreachable);
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

    fn snapshot(self: *Rig) !pane.Snapshot {
        try self.session.setRegister(.cpu0, .pc, main_pc);
        var dir = try std.Io.Dir.cwd().openDir(std.testing.io, source_dir, .{});
        defer dir.close(std.testing.io);
        return capture.capture(&self.session, .cpu0, sections(), std.testing.io, dir, 12);
    }
};

const Scene = struct {
    list: draw_list.DrawList,
    frame: raster.Framebuffer,
    theme: *const gui_app.colors.Theme = dark,

    fn init() !Scene {
        const w: u32 = @intCast(area.w);
        const h: u32 = @intCast(area.h);
        return .{ .list = draw_list.DrawList.init(std.testing.allocator, w, h), .frame = try raster.Framebuffer.init(std.testing.allocator, w, h) };
    }

    fn deinit(self: *Scene) void {
        self.list.deinit();
        self.frame.deinit(std.testing.allocator);
    }

    fn render(self: *Scene, snapshot: *const pane.Snapshot, marks: *const pane.Marks) !void {
        self.list.clear();
        try pane.draw(&self.list, self.theme, area, snapshot, marks);
        raster.draw(&self.frame, &self.list, font.atlas);
    }

    // TEMPORARY golden dump, never committed.

    fn digest(self: *const Scene) u64 {
        const hash = std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(self.frame.pixels));
        return hash;
    }

    fn at(self: *const Scene, x: i32, y: i32) draw_list.Color {
        return self.frame.at(@intCast(x), @intCast(y));
    }
};

/// A click in the gutter of row `row`.
fn gutterClick(rig: *Rig, marks: *pane.Marks, snapshot: *const pane.Snapshot, row: usize) !?bool {
    const image_now = try image();
    return capture.click(marks, &rig.session, .cpu0, image_now, area, snapshot, area.x + pane.pad + 3, pane.rowRect(area, row).y + 2);
}

test "the gutter, number and text columns line up" {
    try std.testing.expectEqual(@as(usize, 2), pane.number_at);
    try std.testing.expectEqual(@as(usize, 8), pane.text_at);
    try std.testing.expectEqual(@as(usize, 12), pane.rows(area));
    try std.testing.expectEqual(pane.pad + 6 * pane.row_h, pane.rowRect(area, 6).y);
}

test "the rows centre on the line pc belongs to" {
    var rig: Rig = undefined;
    try rig.init();
    const snapshot = try rig.snapshot();
    try std.testing.expectEqual(pane.State.shown, snapshot.state);
    try std.testing.expectEqualStrings("pacbti_smoke.S", snapshot.path());
    try std.testing.expectEqual(@as(u32, 18), snapshot.current);
    try std.testing.expectEqual(@as(usize, 12), snapshot.count);
    try std.testing.expectEqual(@as(u32, 12), snapshot.rows[0].number);
    try std.testing.expectEqualStrings("    pacbti r12, lr, sp", snapshot.rows[current_row].text());
}

test "an address with no line and a missing source each say so" {
    var rig: Rig = undefined;
    try rig.init();
    try rig.session.setRegister(.cpu0, .pc, 0x40);
    const none = try capture.capture(&rig.session, .cpu0, sections(), std.testing.io, std.Io.Dir.cwd(), 12);
    try std.testing.expectEqual(pane.State.no_line, none.state);
    try rig.session.setRegister(.cpu0, .pc, main_pc);
    var elsewhere = try std.Io.Dir.cwd().openDir(std.testing.io, "tests/fixtures", .{});
    defer elsewhere.close(std.testing.io);
    const missing = try capture.capture(&rig.session, .cpu0, sections(), std.testing.io, elsewhere, 12);
    try std.testing.expectEqual(pane.State.no_file, missing.state);
    try std.testing.expectEqual(@as(u32, 18), missing.current);
}

test "a gutter click sets and then clears a breakpoint on a real session" {
    var rig: Rig = undefined;
    try rig.init();
    const snapshot = try rig.snapshot();
    var marks: pane.Marks = .{};
    try std.testing.expectEqual(@as(?bool, true), try gutterClick(&rig, &marks, &snapshot, mark_row));
    try std.testing.expectEqual(@as(usize, 1), marks.len);
    const id = marks.items[0].id;
    try std.testing.expect(try rig.session.breakpointExists(.cpu0, id));
    try std.testing.expectEqual(mark_line, marks.items[0].line);
    var scene = try Scene.init();
    defer scene.deinit();
    try scene.render(&snapshot, &marks);
    for (0..12) |row| {
        const mark = pane.markRect(area, row);
        try std.testing.expectEqual(row == mark_row, std.meta.eql(dark.bad, scene.at(mark.x + 1, mark.y + 1)));
        const edge = scene.at(area.w - 1, pane.rowRect(area, row).y + 1);
        try std.testing.expect(std.meta.eql(if (row == current_row) dark.band else dark.background, edge));
    }
    try std.testing.expectEqual(@as(?bool, false), try gutterClick(&rig, &marks, &snapshot, mark_row));
    try std.testing.expectEqual(@as(usize, 0), marks.len);
    try std.testing.expect(!try rig.session.breakpointExists(.cpu0, id));
    try std.testing.expectEqual(@as(?u32, null), pane.lineAt(area, &snapshot, area.w / 2, pane.rowRect(area, mark_row).y + 2));
}

test "a pane too narrow draws nothing" {
    var rig: Rig = undefined;
    try rig.init();
    const snapshot = try rig.snapshot();
    var list = draw_list.DrawList.init(std.testing.allocator, 400, 200);
    defer list.deinit();
    try pane.draw(&list, dark, .{ .x = 0, .y = 0, .w = pane.min_w - 1, .h = 200 }, &snapshot, &.{});
    try std.testing.expectEqual(@as(usize, 0), list.commands.items.len);
}

test "the current line and a mark rasterise to the pinned golden frame" {
    var rig: Rig = undefined;
    try rig.init();
    const snapshot = try rig.snapshot();
    var marks: pane.Marks = .{};
    _ = try gutterClick(&rig, &marks, &snapshot, mark_row);
    var scene = try Scene.init();
    defer scene.deinit();
    try scene.render(&snapshot, &marks);
    try std.testing.expectEqual(@as(u64, 9083513172933800025), scene.digest());
}

test "in the light palette the current line and a mark rasterise to their own golden" {
    var rig: Rig = undefined;
    try rig.init();
    const snapshot = try rig.snapshot();
    var marks: pane.Marks = .{};
    _ = try gutterClick(&rig, &marks, &snapshot, mark_row);
    var scene = try Scene.init();
    defer scene.deinit();
    scene.theme = light;
    try scene.render(&snapshot, &marks);
    try std.testing.expectEqual(@as(u64, 18171556404919912823), scene.digest());
}
