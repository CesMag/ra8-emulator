//! Covers src/interfaces/gui/flame/open.zig (RA8EMU-837): a flame frame
//! resolves to its function's first line on the uart_irq_echo fixture,
//! matching what addr2line gives for the symbol's address (main.c:125,
//! :175, :298), and a frame in dfu_bootloader.elf, which has symbols but no
//! line table, falls back to disassembly at the function's start.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");

const elf = ra8.board.image.elf;
const dwarf_line = ra8.session.dwarf.line;
const draw_list = ra8.render.draw_list;
const flame_open = gui_app.flame.open;
const flame_model = gui_app.flame.model;
const flame_pane = gui_app.flame_pane;

const lined_bytes = @embedFile("../../../fixtures/uart/uart_irq_echo.elf");
const bare_bytes = @embedFile("../../../fixtures/dfu/dfu_bootloader.elf");

fn lined() !elf.Image {
    return elf.Image.init(lined_bytes);
}

fn bare() !elf.Image {
    return elf.Image.init(bare_bytes);
}

fn expectLine(name: []const u8, address: u32, line: u32) !void {
    const image = try lined();
    const target = flame_open.resolve(image, dwarf_line.ofImage(image), name);
    try std.testing.expect(target == .source);
    try std.testing.expectEqual(address, target.source.address);
    try std.testing.expectEqual(line, target.source.place.line);
}

test "a frame resolves to its function's first line, as addr2line does" {
    try expectLine("uart_irq_rxi_isr", 0x0200_0358, 125);
    try expectLine("uart_irq_rx_cb", 0x0200_039C, 175);
    try expectLine("main", 0x0200_057C, 298);
}

test "opening a lined frame fills the source pane with that line current" {
    const image = try lined();
    const opened = try flame_open.open(image, dwarf_line.ofImage(image), "uart_irq_rx_cb", std.testing.io, std.Io.Dir.cwd(), 12);
    try std.testing.expect(opened.source != null);
    try std.testing.expectEqual(@as(?u32, null), opened.disasm);
    try std.testing.expectEqual(@as(u32, 175), opened.source.?.current);
    try std.testing.expectEqual(@as(u32, 0x0200_039C), opened.source.?.pc);
    try std.testing.expect(std.mem.endsWith(u8, opened.source.?.path(), "main.c"));
    try std.testing.expectEqualStrings("", opened.status());
}

test "a frame with no line info opens disassembly at its start with a status" {
    const image = try bare();
    const sections = dwarf_line.ofImage(image);
    try std.testing.expectEqual(flame_open.Target{ .disasm = 0x0200_65EC }, flame_open.resolve(image, sections, "ra8_boot_fault_dispatch"));
    const opened = try flame_open.open(image, sections, "dfu_host_abi.entry", std.testing.io, std.Io.Dir.cwd(), 12);
    try std.testing.expect(opened.source == null);
    try std.testing.expectEqual(@as(?u32, 0x0200_1FDC), opened.disasm);
    try std.testing.expectEqualStrings("dfu_host_abi.entry has no line info; disassembly at 02001FDC", opened.status());
}

test "a name the image does not size says so and opens nothing" {
    const image = try lined();
    const opened = try flame_open.open(image, dwarf_line.ofImage(image), "no_such_function", std.testing.io, std.Io.Dir.cwd(), 12);
    try std.testing.expect(opened.source == null and opened.disasm == null);
    try std.testing.expectEqualStrings("no_such_function is not a sized function in the image", opened.status());
}

test "a click opens the frame under it and ignores the root and empty space" {
    var model = flame_model.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.load("main;uart_irq_rx_cb 3\nmain 1\n");
    const area = draw_list.Rect{ .x = 0, .y = 0, .w = 200, .h = 120 };
    const image = try lined();
    const sections = dwarf_line.ofImage(image);
    const x = flame_pane.pad + 1;
    var found: ?i32 = null;
    var y: i32 = 0;
    while (y < area.h) : (y += 1) {
        const node = flame_pane.nodeAt(area, &model, x, y) orelse continue;
        if (std.mem.eql(u8, model.name(node), "uart_irq_rx_cb")) found = y;
    }
    const at = found orelse return error.FrameNotDrawn;
    const opened = (try flame_open.click(area, &model, x, at, image, sections, std.testing.io, std.Io.Dir.cwd(), 12)).?;
    try std.testing.expectEqual(@as(u32, 175), opened.source.?.current);
    var root_y: ?i32 = null;
    y = 0;
    while (y < area.h) : (y += 1) {
        if (flame_pane.nodeAt(area, &model, x, y) == 0) root_y = y;
    }
    if (root_y) |ry| try std.testing.expect((try flame_open.click(area, &model, x, ry, image, sections, std.testing.io, std.Io.Dir.cwd(), 12)) == null);
    try std.testing.expect((try flame_open.click(area, &model, x, area.h + 50, image, sections, std.testing.io, std.Io.Dir.cwd(), 12)) == null);
}
