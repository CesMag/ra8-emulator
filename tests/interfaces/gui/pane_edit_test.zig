//! Covers src/interfaces/gui/pane_edit.zig (RA8EMU-742) on a real session over the
//! uart_irq_echo fixture: a click on r4's value and DEADBEEF then Enter
//! writes r4, a click on a byte in SRAM and A5 then Enter writes that byte,
//! Escape leaves the value alone, and clicks off a value pick nothing.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");

const draw_list = ra8.render.draw_list;
const font = ra8.render.font;
const hex_entry = gui_app.hex_entry;
const memory_pane = gui_app.memory_pane;
const registers_pane = gui_app.registers_pane;
const registers_capture = gui_app.registers_capture;
const edit = gui_app.pane_edit;
const memmap = ra8.chip.core.memmap;

const Rect = draw_list.Rect;

const image_path = "tests/fixtures/uart/uart_irq_echo.elf";
/// Two rows of SRAM the fixture never touches before it runs.
const spare = memmap.sram_base + 0x0004_0000;
/// Three register columns of eight rows: r4 is row 4 of the first.
const registers_area = Rect{ .x = 0, .y = 0, .w = 2 * registers_pane.pad + 3 * @as(i32, @intCast(font.textWidth(registers_pane.column_len))), .h = 2 * registers_pane.pad + 8 * registers_pane.row_h };
const memory_area = Rect{ .x = 0, .y = 0, .w = memory_pane.min_w, .h = 2 * memory_pane.pad + 2 * memory_pane.row_h };
const r4: usize = 4;

fn press(e: *edit.Edit, code: u32, session: *ra8.session.session_api.Session) !edit.State {
    return e.key(code, session, .cpu0);
}

test "a click on r4's value and DEADBEEF then Enter writes r4" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image_path });
    defer opened.deinit();
    const session = opened.session();
    const at = edit.registerOrigin(registers_area, r4).?;
    const picked = edit.registerAt(registers_area, at.x + 1, at.y + 1).?;
    try std.testing.expectEqual(r4, picked);
    try std.testing.expectEqual(ra8.session.session_api.Register.r4, registers_capture.shown[picked]);
    var e = edit.Edit.begin(.{ .register = picked });
    e.typed("deadbeef");
    try std.testing.expectEqual(edit.State.written, try press(&e, hex_entry.codes.enter, session));
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), try session.register(.cpu0, .r4));
}

test "a click on an SRAM byte and A5 then Enter writes that byte" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image_path });
    defer opened.deinit();
    const session = opened.session();
    const snapshot = try gui_app.memory_capture.capture(session, .cpu0, spare, 2);
    const row = memory_pane.rowOrigin(memory_area, 1);
    const x = row.x + @as(i32, @intCast(font.textWidth(memory_pane.hexColumn(3)))) + 1;
    const address = edit.byteAt(memory_area, &snapshot, x, row.y + 1).?;
    try std.testing.expectEqual(spare + 16 + 3, address);
    var e = edit.Edit.begin(.{ .byte = address });
    e.typed("a5");
    try std.testing.expectEqual(edit.State.written, try press(&e, hex_entry.codes.enter, session));
    var bytes: [3]u8 = undefined;
    try session.read(.cpu0, address - 1, &bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0xA5, 0 }, &bytes);
}

test "escape leaves the register alone" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image_path });
    defer opened.deinit();
    const session = opened.session();
    const before = try session.register(.cpu0, .r5);
    var e = edit.Edit.begin(.{ .register = 5 });
    e.typed("1234");
    try std.testing.expectEqual(edit.State.editing, try press(&e, hex_entry.codes.backspace, session));
    try std.testing.expectEqual(edit.State.cancelled, try press(&e, hex_entry.codes.escape, session));
    try std.testing.expectEqual(before, try session.register(.cpu0, .r5));
}

test "clicks off a value pick nothing" {
    const cell = registers_pane.cellRect(registers_area, registers_pane.open, r4).?;
    try std.testing.expectEqual(@as(?usize, null), edit.registerAt(registers_area, cell.x + 2, cell.y + 2));
    var snapshot: memory_pane.Snapshot = .{ .base = spare, .count = 1 };
    const row = memory_pane.rowOrigin(memory_area, 0);
    const x = row.x + @as(i32, @intCast(font.textWidth(memory_pane.hexColumn(0)))) + 1;
    try std.testing.expectEqual(@as(?u32, null), edit.byteAt(memory_area, &snapshot, x, row.y + 1));
    snapshot.readable[0] = true;
    try std.testing.expectEqual(@as(?u32, spare), edit.byteAt(memory_area, &snapshot, x, row.y + 1));
    try std.testing.expectEqual(@as(?u32, null), edit.byteAt(memory_area, &snapshot, row.x + 1, row.y + 1));
    try std.testing.expectEqual(@as(?u32, null), edit.byteAt(memory_area, &snapshot, x, row.y + memory_pane.row_h + 1));
}
