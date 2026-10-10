//! `--frame-out PATH`: what the panel shows when the run ends, as a PNG
//! (RA8EMU-73). It scans the GLCDC once more with a capture armed on the
//! output stage, after the report has printed, so the report is unchanged.
//! A run that left no frame still gets the board view, round a dark panel.
//! The PNG is the board view: the panel inside the EK-RA8D2 outline with
//! the user LEDs as the pins left them (board_view.zig).
const std = @import("std");
const Board = @import("ra8_board").board.Board;
const eink = @import("ra8_components").eink;
const eink_wire = @import("ra8_components").eink.wire;
const png = @import("ra8_render").png;
const board_view = @import("ra8_render").board_view;
const board_leds = @import("ra8_session").board_leds;

/// The panel's size, the size of the view that was written, and whether
/// the GLCDC gave a frame (when it did not, the panel is drawn dark).
pub const Saved = struct { width: u32, height: u32, view: board_view.Size, frame: bool, eink: bool = false };

/// A panel has no transparency: what reaches the glass is the colour, so
/// every pixel goes out opaque. `rgba` holds four bytes per pixel.
pub fn opaqueRgba(pixels: []const u32, rgba: []u8) png.Error!void {
    try png.fromArgb(pixels, rgba);
    var at: usize = 3;
    while (at < rgba.len) : (at += png.bytes_per_pixel) rgba[at] = 0xFF;
}

/// Scan the panel into a buffer and write the board view to `path` as a
/// PNG. A run with no frame (an LED-only example) still gets the view,
/// with the LEDs as the pins left them round a dark panel.
pub fn save(allocator: std.mem.Allocator, io: std.Io, board: *Board, path: []const u8, panel_only: bool) !Saved {
    if (board.asks.attached_eink) |panel| return saveEink(allocator, io, panel, path);
    const unit = &board.display;
    const scanned = unit.panelWidth() != 0 and unit.panelHeight() != 0;
    const width = if (scanned) unit.panelWidth() else board_view.panel_width;
    const height = if (scanned) unit.panelHeight() else board_view.panel_height;
    const pixels = try allocator.alloc(u32, @as(usize, width) * height);
    defer allocator.free(pixels);
    @memset(pixels, 0);
    const frame = scanned and scan(board, pixels, width, height);
    if (!frame) @memset(pixels, 0);
    // No GLCDC frame: the board's own e-ink panel, once refreshed (RA8EMU-591).
    if (!frame and board.panel.refreshes != 0) return saveEink(allocator, io, &board.panel, path);
    const view = if (panel_only) board_view.Size{ .width = width, .height = height } else board_view.size(width, height);
    if (panel_only) {
        try write(allocator, io, pixels, view, path);
    } else {
        const canvas = try allocator.alloc(u32, @as(usize, view.width) * view.height);
        defer allocator.free(canvas);
        board_view.compose(canvas, pixels, width, height, &board_leds.of(board));
        try write(allocator, io, canvas, view, path);
    }
    return .{ .width = width, .height = height, .view = view, .frame = frame };
}

fn scan(board: *Board, pixels: []u32, width: u32, height: u32) bool {
    const unit = &board.display;
    unit.output.capture = .{ .pixels = pixels, .width = width, .height = height };
    defer unit.output.capture = null;
    return unit.scanOut() != null;
}

/// Save the requested e-ink panel's refreshed glass, as grey pixels.
fn saveEink(allocator: std.mem.Allocator, io: std.Io, panel: *const eink.Panel, path: []const u8) !Saved {
    const width: u32 = panel.planes.geometry.width;
    const height: u32 = panel.planes.geometry.height;
    const view = board_view.Size{ .width = width, .height = height };
    const rgba = try allocator.alloc(u8, @as(usize, width) * height * png.bytes_per_pixel);
    defer allocator.free(rgba);
    if (panel.planes.glass.pixels.len == 0) {
        for (0..@as(usize, width) * height) |at| @memcpy(rgba[at * png.bytes_per_pixel ..][0..png.bytes_per_pixel], &[_]u8{ 0, 0, 0, 0xFF });
    } else try grayRgba(panel.planes.glass.pixels, rgba);
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var staging: [4096]u8 = undefined;
    var writer = file.writer(io, &staging);
    try png.encode(allocator, &writer.interface, width, height, rgba);
    try writer.interface.flush();
    return .{ .width = width, .height = height, .view = view, .frame = panel.refreshes != 0, .eink = true };
}

/// Expand 8-bit glass samples into opaque, equal-channel RGB pixels.
pub fn grayRgba(pixels: []const u8, rgba: []u8) png.Error!void {
    if (rgba.len != pixels.len * png.bytes_per_pixel) return png.Error.BadShape;
    for (pixels, 0..) |gray, index| {
        const at = index * png.bytes_per_pixel;
        rgba[at] = gray;
        rgba[at + 1] = gray;
        rgba[at + 2] = gray;
        rgba[at + 3] = 0xFF;
    }
}

fn write(allocator: std.mem.Allocator, io: std.Io, canvas: []const u32, view: board_view.Size, path: []const u8) !void {
    const rgba = try allocator.alloc(u8, canvas.len * png.bytes_per_pixel);
    defer allocator.free(rgba);
    try opaqueRgba(canvas, rgba);
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var staging: [4096]u8 = undefined;
    var writer = file.writer(io, &staging);
    try png.encode(allocator, &writer.interface, view.width, view.height, rgba);
    try writer.interface.flush();
}

/// One line for the end of the run: what went into the view, and where.
pub fn report(out: anytype, io: std.Io, board: *Board, path: ?[]const u8, panel_only: bool) !void {
    const target = path orelse return;
    const saved = try save(std.heap.page_allocator, io, board, target, panel_only);
    if (saved.eink) {
        if (!saved.frame) return out.print("frame-out: no e-ink refresh, the {d}x{d} grey glass written to {s}\n", .{
            saved.width, saved.height, target,
        });
        return out.print("frame-out: {d}x{d} grey e-ink glass written to {s}\n", .{ saved.width, saved.height, target });
    }
    if (!saved.frame) {
        if (panel_only) return out.print("frame-out: no panel frame, a dark {d}x{d} panel written to {s}\n", .{
            saved.view.width, saved.view.height, target,
        });
        return out.print("frame-out: no panel frame, the LEDs on a {d}x{d} board view written to {s}\n", .{
            saved.view.width, saved.view.height, target,
        });
    }
    if (panel_only) return out.print("frame-out: {d}x{d} panel written to {s}\n", .{ saved.width, saved.height, target });
    try out.print("frame-out: {d}x{d} panel on a {d}x{d} board view written to {s}\n", .{
        saved.width, saved.height, saved.view.width, saved.view.height, target,
    });
}
