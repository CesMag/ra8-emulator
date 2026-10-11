//! Covers src/interfaces/gui/ui/stack_pane.zig (RA8EMU-744) on the
//! uart_irq_echo fixture, the one image with .debug_frame, .debug_line and
//! .symtab, its snapshot filled the way the shell fills it: the session's
//! backtrace answer (RA8EMU-1125) unpacked by gui/shell_stack.zig. The
//! columns line up, a click maps to its frame, a pane too narrow draws
//! nothing, and the stop rasterises to a pinned golden frame. The walk
//! itself is tested in tests/interfaces/rpc/session/backtrace_test.zig.
const std = @import("std");
const dark = &@import("gui_app").colors.palettes.dark;
const light = &@import("gui_app").colors.palettes.light;
const Theme = @import("gui_app").colors.Theme;
const ra8 = @import("ra8");
const gui_app = @import("gui_app");

const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;
const pane = gui_app.stack_pane;
const server = ra8.rpc.session.server;
const proto = ra8.rpc.session.rpc;

const Rect = draw_list.Rect;
/// Room for 64 characters past the pc and six rows.
const area = Rect{ .x = 0, .y = 0, .w = 2 * pane.pad + 2 + @as(i32, @intCast(font.textWidth(pane.name_at + 48))), .h = 2 * pane.pad + 6 * pane.row_h };

const image_path = "tests/fixtures/uart/uart_irq_echo.elf";
/// ra8_sci_init's first instruction (its symbol is 0x02001A71).
const sci_init: u32 = 0x0200_1A70;
const golden: u64 = 18040179402476691476;

/// The fixture stopped on ra8_sci_init's first instruction.
fn stopped() !ra8.session.harness.Harness {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image_path });
    errdefer opened.deinit();
    const session = opened.session();
    _ = try session.setBreakpoint(.cpu0, .{ .address = sci_init });
    session.live.budget = 200_000;
    _ = try session.run(.cpu0, .cont);
    try std.testing.expectEqual(sci_init, try session.register(.cpu0, .pc));
    return opened;
}

fn imageOf(context: *anyopaque, core: usize) ?ra8.session.symbols.Image {
    const harness: *ra8.session.harness.Harness = @ptrCast(@alignCast(context));
    return harness.loadedImage(if (core == 0) .cpu0 else .cpu1);
}

fn noMap(_: *anyopaque, _: usize, _: bool, _: []u8) anyerror![]const u8 {
    return error.NoImage;
}

/// cpu0's chain as the shell's stack leaf would show it.
fn walk(opened: *ra8.session.harness.Harness) !pane.Snapshot {
    var scratch: [proto.backtrace_bytes]u8 = undefined;
    var context: server.Context = .{ .session = opened.session(), .scratch = &scratch };
    context.mapping = .{ .context = opened, .mapFn = noMap, .imageFn = imageOf };
    return switch (ra8.rpc.session.backtrace.backtrace(&context, .{ .core = .cpu0 })) {
        .ok => |chain| gui_app.shell.stack.unpack(chain),
        .err => error.Refused,
    };
}

const Scene = struct {
    list: draw_list.DrawList,
    frame: raster.Framebuffer,
    /// The palette the scene paints with (RA8EMU-961).
    theme: *const Theme = dark,

    fn init() !Scene {
        const w: u32 = @intCast(area.w);
        const h: u32 = @intCast(area.h);
        return .{ .list = draw_list.DrawList.init(std.testing.allocator, w, h), .frame = try raster.Framebuffer.init(std.testing.allocator, w, h) };
    }

    fn deinit(self: *Scene) void {
        self.list.deinit();
        self.frame.deinit(std.testing.allocator);
    }

    fn render(self: *Scene, snapshot: *const pane.Snapshot, selected: usize) !void {
        try pane.draw(&self.list, self.theme, area, snapshot, selected);
        raster.draw(&self.frame, &self.list, font.atlas);
    }

    // TEMPORARY golden dump, never committed.

    fn digest(self: *const Scene) u64 {
        const hash = std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(self.frame.pixels));
        return hash;
    }
};

test "the gutter, number, pc and function columns line up" {
    try std.testing.expectEqual(@as(usize, 2), pane.number_at);
    try std.testing.expectEqual(@as(usize, 6), pane.pc_at);
    try std.testing.expectEqual(@as(usize, 16), pane.name_at);
    try std.testing.expectEqual(@as(usize, 6), pane.rows(area));
    try std.testing.expectEqual(pane.pad + 2 * pane.row_h, pane.rowRect(area, 2).y);
}

test "a click picks the frame on its row and nothing past the last" {
    var snapshot: pane.Snapshot = .{ .count = 3 };
    try std.testing.expectEqual(@as(?usize, 0), pane.frameAt(area, &snapshot, pane.pad));
    try std.testing.expectEqual(@as(?usize, 2), pane.frameAt(area, &snapshot, pane.rowRect(area, 2).y + 1));
    try std.testing.expectEqual(@as(?usize, null), pane.frameAt(area, &snapshot, pane.rowRect(area, 3).y + 1));
    try std.testing.expectEqual(@as(?usize, null), pane.frameAt(area, &snapshot, 0));
}

test "a pane too narrow draws nothing" {
    var list = draw_list.DrawList.init(std.testing.allocator, 64, 64);
    defer list.deinit();
    const snapshot: pane.Snapshot = .{ .count = 1 };
    try pane.draw(&list, dark, .{ .x = 0, .y = 0, .w = pane.min_w - 1, .h = 64 }, &snapshot, 0);
    try std.testing.expectEqual(@as(usize, 0), list.commands.items.len);
}

test "the stop rasterises to the pinned golden frame" {
    var opened = try stopped();
    defer opened.deinit();
    const snapshot = try walk(&opened);
    var scene = try Scene.init();
    defer scene.deinit();
    try scene.render(&snapshot, 1);
    try std.testing.expectEqual(golden, scene.digest());
}

test "the stop rasterises to the pinned golden frame in the light theme" {
    var opened = try stopped();
    defer opened.deinit();
    const snapshot = try walk(&opened);
    var scene = try Scene.init();
    defer scene.deinit();
    scene.theme = light;
    try scene.render(&snapshot, 1);
    try std.testing.expectEqual(@as(u64, 13701500343231273968), scene.digest());
}
