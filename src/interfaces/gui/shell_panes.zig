//! The shell's pane painter (RA8EMU-773): fills each leaf body of the shell
//! frame (RA8EMU-764) by the leaf's kind. The shell reaches its session only
//! over the link, and no pane has a feed there yet, so each body names the
//! feed it waits for; each feed replaces its note in its own change under
//! RA8EMU-772. The console leaf shows the console's log once it holds output
//! (RA8EMU-787), and the board leaf the board pane: the board's outline, its
//! LEDs and switches, and the panel image once a frame has arrived
//! (RA8EMU-790, RA8EMU-1119), and the devices leaf the fitted parts once the session has
//! listed them (RA8EMU-792), and the camera leaf its source picker
//! (RA8EMU-796); with a plug picker (RA8EMU-802) the devices leaf ends in
//! its field, and with a file field (RA8EMU-799) so does the camera leaf.
//! A registers leaf draws its bound core's registers once the session has
//! answered a read of them (RA8EMU-821), and a memory leaf the rows from
//! its core's SP once they have been read, and a disassembly leaf the
//! instructions from its core's PC.
//! An empty leaf stays blank.
const Theme = @import("ui/colors.zig").Theme;
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const pane_layout = @import("ui/pane_layout.zig");
const shell_frame = @import("ui/shell_frame.zig");
const console_pane = @import("ui/console_pane.zig");
const shell_console = @import("shell_console.zig");
const shell_board = @import("shell_board.zig");
const shell_board_input = @import("shell_board_input.zig");
const board_pane = @import("ui/board_pane.zig");
const fit = @import("ui/fit.zig");
const shell_devices = @import("shell_devices.zig");
const shell_fault = @import("shell_fault.zig");
const shell_camera = @import("shell_camera.zig");
const shell_plug = @import("shell_plug.zig");
const shell_camera_file = @import("shell_camera_file.zig");
const shell_registers = @import("shell_registers.zig");
const registers_pane = @import("ui/registers_pane.zig");
const shell_memory = @import("shell_memory.zig");
const memory_pane = @import("ui/memory_pane.zig");
const disasm_pane = @import("ui/disasm_pane.zig");
const disasm_capture = @import("disasm_capture.zig");
const shell_stack = @import("shell_stack.zig");
const stack_pane = @import("ui/stack_pane.zig");

const Rect = draw_list.Rect;

/// The note a leaf of `kind` shows, or null when it draws nothing.
pub fn waitingFor(kind: pane_layout.Kind) ?[]const u8 {
    return switch (kind) {
        .empty => null,
        .board => "waiting for the board's frames",
        .camera => "waiting for the camera feed",
        .console => "waiting for console output",
        .devices => "waiting for the device list",
        .registers => "waiting for the registers",
        .memory => "waiting for memory",
        .disasm => "waiting for the code",
        .stack => "waiting for the call stack",
    };
}

/// The feeds the panes draw from; a missing one leaves its note up.
pub const Panes = struct {
    console: ?*const shell_console.Console = null,
    board: ?*const shell_board.Board = null,
    /// The pointer on the board leaf, for the switch it holds down.
    board_input: ?*const shell_board_input.Pointer = null,
    devices: ?*const shell_devices.Devices = null,
    /// Each device row's fault mode, drawn in its cell (RA8EMU-817).
    faults: ?*const shell_fault.Faults = null,
    camera: ?*const shell_camera.Camera = null,
    plug: ?*shell_plug.Plug = null,
    camera_file: ?*shell_camera_file.CameraFile = null,
    registers: ?*const shell_registers.Pair = null,
    memory: ?*const shell_memory.Pair = null,
    /// The memory read from each core's PC, for the disassembly leaves.
    code: ?*const shell_memory.Pair = null,
    stack: ?*const shell_stack.Pair = null,

    pub fn painter(self: *Panes) shell_frame.Painter {
        return .{ .context = self, .paint = paint };
    }
};

/// Where the note's text starts in `body`: inset by the frame's pad and
/// centred down the body. Null when the body cannot hold one row.
pub fn noteAt(body: Rect) ?struct { x: i32, y: i32, room: u32 } {
    const room = body.w - 2 * shell_frame.pad;
    const glyph: i32 = font.glyph_h;
    if (room <= 0 or body.h < glyph) return null;
    return .{ .x = body.x + shell_frame.pad, .y = body.y + @divTrunc(body.h - glyph, 2), .room = @intCast(room) };
}

fn paint(context: *anyopaque, list: *draw_list.DrawList, theme: *const Theme, pane: pane_layout.Pane, body: Rect) anyerror!void {
    const self: *Panes = @ptrCast(@alignCast(context));
    if (pane.kind == .console) if (self.console) |console| {
        if (console.hasOutput()) return console_pane.draw(list, theme, body, &console.log, 0);
    };
    if (pane.kind == .devices) if (self.devices) |devices| {
        if (self.plug) |plug| if (devices.answered and !devices.refused) {
            try shell_plug.draw(list, theme, body, devices, plug);
            return drawFaults(self, list, theme, shell_plug.rowsRect(body), devices);
        };
        if (devices.answered and devices.note() == null) {
            try shell_devices.draw(list, theme, body, devices);
            return drawFaults(self, list, theme, body, devices);
        }
    };
    if (pane.kind == .camera) if (self.camera) |camera| {
        if (self.camera_file) |file| return shell_camera_file.draw(list, theme, body, camera, file);
        return shell_camera.draw(list, theme, body, camera);
    };
    if (pane.kind == .registers) if (self.registers) |pair| {
        const model = pair.of(pane.core);
        if (model.now) |now| return registers_pane.draw(list, theme, body, now, model.before, model.fold);
    };
    if (pane.kind == .memory) if (self.memory) |pair| {
        if (pair.of(pane.core).now) |*now| return memory_pane.draw(list, theme, body, now);
    };
    if (pane.kind == .disasm) if (self.code) |pair| {
        const model = pair.of(pane.core);
        if (model.now) |*read| return drawCode(list, theme, body, model.from, read);
    };
    if (pane.kind == .stack) if (self.stack) |pair| {
        if (pair.of(pane.core).now) |*now| return stack_pane.draw(list, theme, body, now, 0);
    };
    if (pane.kind == .board) if (self.board) |board| {
        const pressed = if (self.board_input) |pointer| pointer.press.held else null;
        if (!board_pane.Layout.of(body).board.empty()) return board_pane.draw(list, theme, body, board.view(pressed));
        // A leaf too small for the board still shows the panel by itself.
        if (board.hasFrame()) return list.image(fit.fitIn(body, board.width, board.height), board.image());
    };
    const note = noteFor(self, pane) orelse return;
    const at = noteAt(body) orelse return;
    try font.draw(list, at.x, at.y, font.fit(note, at.room), theme.muted);
}

/// The fault cells over a listed devices leaf's rows, when the shell keeps faults.
fn drawFaults(self: *const Panes, list: *draw_list.DrawList, theme: *const Theme, rows: Rect, devices: *const shell_devices.Devices) !void {
    const faults = self.faults orelse return;
    if (devices.note() != null) return;
    try shell_fault.draw(list, theme, rows, devices, faults);
}

/// Instructions decoded forward from `pc` out of the rows read around it.
/// The link carries no breakpoint list yet, so none are marked.
fn drawCode(list: *draw_list.DrawList, theme: *const Theme, body: Rect, pc: u32, read: *const shell_memory.Snapshot) !void {
    const length = read.count * memory_pane.per_row;
    const lines = disasm_capture.decodeRead(pc, read.base, read.bytes[0..length], read.readable[0..length], disasm_pane.rows(body));
    return disasm_pane.draw(list, theme, body, &lines, &.{});
}

/// The note a leaf shows: the device list's, the registers', memory's or
/// the code's own once they have answered.
fn noteFor(self: *const Panes, pane: pane_layout.Pane) ?[]const u8 {
    if (pane.kind == .devices) if (self.devices) |devices| {
        if (devices.note()) |note| return note;
    };
    if (pane.kind == .registers) if (self.registers) |pair| {
        if (pair.of(pane.core).note()) |note| return note;
    };
    if (pane.kind == .memory) if (self.memory) |pair| {
        if (pair.of(pane.core).note()) |note| return note;
    };
    if (pane.kind == .disasm) if (self.code) |pair| {
        if (pair.of(pane.core).refused) return "the session would not read the code";
    };
    if (pane.kind == .stack) if (self.stack) |pair| {
        if (pair.of(pane.core).note()) |note| return note;
    };
    return waitingFor(pane.kind);
}
