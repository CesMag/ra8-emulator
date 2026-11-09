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
const Theme = @import("../ui/colors.zig").Theme;
const widget = @import("ra8_widget");
const draw_list = @import("ra8_render").draw_list;
const widget_paint = @import("ra8_render").widget_paint;
const font = @import("ra8_render").font;
const pane_layout = @import("../ui/pane_layout.zig");
const shell_frame = @import("../ui/shell/frame.zig");
const console_pane = @import("../ui/console_pane.zig");
const locals_pane = @import("../ui/locals_pane.zig");
const map_pane = @import("../ui/map_pane.zig");
const console_strip = @import("../ui/console_strip.zig");
const shell_console = @import("console.zig");
const shell_board = @import("board/board.zig");
const shell_board_input = @import("board/input.zig");
const board_pane = @import("../ui/board_pane.zig");
const fit = @import("../ui/fit.zig");
const shell_devices = @import("devices.zig");
const shell_fault = @import("fault.zig");
const shell_camera = @import("camera/camera.zig");
const shell_plug = @import("plug.zig");
const shell_camera_file = @import("camera/file.zig");
const shell_registers = @import("registers.zig");
const shell_breaks = @import("breaks.zig");
const registers_pane = @import("../ui/registers_pane.zig");
const shell_register_edit = @import("register_edit.zig");
const shell_memory = @import("memory.zig");
const shell_memory_field = @import("memory_field.zig");
const memory_pane = @import("../ui/memory_pane.zig");
const disasm_pane = @import("../ui/disasm_pane.zig");
const disasm_capture = @import("../disasm_capture.zig");
const shell_stack = @import("stack.zig");
const shell_locals = @import("locals.zig");
const shell_map = @import("map.zig");
const stack_pane = @import("../ui/stack_pane.zig");
const shell_source = @import("source.zig");
const source_pane = @import("../ui/source_pane.zig");
const timeline_model = @import("../timeline_model.zig");
const timeline_pane = @import("../timeline_pane.zig");
const diff_pane = @import("../ui/diff_pane.zig");
const branch_tree = @import("../branch_tree.zig");
const branch_state = @import("branch_state.zig");

const geom = @import("../geom.zig");
const Rect = geom.Rect;

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
        .source => "waiting for the source line",
        .timeline => "waiting for the trace",
        .locals => "waiting for the locals",
        .map => "waiting for an image",
        .diff => "waiting for diff results",
        .branches => "waiting for the branches",
        .host_metrics => "waiting for host metrics",
        .device_metrics => "waiting for device metrics",
    };
}

/// The feeds the panes draw from; a missing one leaves its note up.
pub const Panes = struct {
    device_metrics: ?*const [2]@import("ra8_session").device_metrics.Snapshot = null,
    device_windows: ?*const [2]@import("ra8_session").device_metrics.Window = null,
    host_metrics: ?*const @import("ra8_host").metrics.Sampler = null,
    console: ?*const shell_console.Console = null,
    board: ?*shell_board.Board = null,
    /// The pointer on the board leaf, for the switch it holds down.
    board_input: ?*const shell_board_input.Pointer = null,
    devices: ?*const shell_devices.Devices = null,
    /// Each device row's fault mode, drawn in its cell (RA8EMU-817).
    faults: ?*const shell_fault.Faults = null,
    camera: ?*const shell_camera.Camera = null,
    plug: ?*shell_plug.Plug = null,
    camera_file: ?*shell_camera_file.CameraFile = null,
    registers: ?*const shell_registers.Pair = null,
    /// The open register field and a refused write's note (RA8EMU-946).
    edit: ?*const shell_register_edit.Editor = null,
    memory: ?*const shell_memory.Pair = null,
    /// The memory leaf's address field (RA8EMU-934).
    memory_field: ?*shell_memory_field.Pin = null,
    /// The run-to points clicked on the disassembly leaves (RA8EMU-1171).
    breaks: ?*const shell_breaks.Breaks = null,
    /// The memory read from each core's PC, for the disassembly leaves.
    code: ?*const shell_memory.Pair = null,
    stack: ?*const shell_stack.Pair = null,
    locals: ?*const shell_locals.Pair = null,
    /// The image's sections over the board's regions (RA8EMU-781).
    map: ?*const shell_map.State = null,
    source: ?*shell_source.Pair = null,
    /// The timeline's RTOS record (RA8EMU-838).
    timeline: ?*timeline_model.Model = null,
    /// Greys register and memory panes while moving backward or seeking (Slice 22.4).
    busy: bool = false,
    diff: ?*const diff_pane.DiffView = null,
    /// The branch tree leaf's list, asked over the link.
    branches: ?*const branch_state.Feed = null,

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

/// `body` in the draw list's own type, for the leaves that still paint
/// through the list (RA8EMU-1157 temporary).
fn toList(r: Rect) draw_list.Rect {
    return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
}

/// The mono-font leaves: registers and memory paint through the widget
/// target over the list (RA8EMU-1169).
fn drawMono(self: *Panes, list: *draw_list.DrawList, theme: *const Theme, pane: pane_layout.Pane, body: Rect) anyerror!bool {
    if (pane.kind == .registers) if (self.registers) |pair| {
        const model = pair.of(pane.core);
        if (model.now) |now| {
            var mono_target = widget_paint.Target{ .list = list, .mono = true };
            const mono_paint = mono_target.paint();
            try registers_pane.draw(&mono_paint, theme, body, now, model.before, model.fold);
            if (self.edit) |edit| edit.draw(&mono_paint, theme, body, model.fold, model.core);
            if (self.busy) {
                try list.fill(toList(body), .{ .r = theme.well.r, .g = theme.well.g, .b = theme.well.b, .a = 160 });
            }
            return true;
        }
    };
    if (pane.kind == .memory) if (self.memory) |pair| {
        if (pair.of(pane.core).now) |*now| {
            var mono_target = widget_paint.Target{ .list = list, .mono = true };
            const mono_paint = mono_target.paint();
            if (self.memory_field) |field| {
                try shell_memory_field.draw(&mono_paint, theme, body, now, field);
            } else try memory_pane.draw(&mono_paint, theme, body, now);
            if (self.busy) {
                try list.fill(toList(body), .{ .r = theme.well.r, .g = theme.well.g, .b = theme.well.b, .a = 160 });
            }
            return true;
        }
    };
    return false;
}

fn paint(context: *anyopaque, list: *draw_list.DrawList, table: *const widget.types.Paint, theme: *const Theme, pane: pane_layout.Pane, body: Rect) anyerror!void {
    const self: *Panes = @ptrCast(@alignCast(context));
    if (pane.kind == .device_metrics) if (self.device_metrics) |metrics| {
        if (self.device_windows) |windows| {
            const core: usize = if (pane.core == .cpu0) 0 else 1;
            return @import("../ui/device_metrics_pane.zig").draw(table, theme, toList(body), &metrics[core], &windows[core]);
        }
    };
    if (pane.kind == .host_metrics) if (self.host_metrics) |metrics| {
        return @import("../ui/host_metrics_pane.zig").draw(table, theme, toList(body), metrics);
    };
    if (pane.kind == .console) if (self.console) |console| {
        if (console.hasOutput()) {
            console_strip.draw(table, theme, toList(body), console.saved);
            return console_pane.draw(table, theme, console_strip.below(toList(body)), &console.log, console.scroll.back);
        }
    };
    if (pane.kind == .timeline) if (self.timeline) |model| {
        const geometry = timeline_pane.Geometry.recorded(toList(body), model) orelse return;
        timeline_pane.draw(table, theme, geometry.area, model, geometry.view);
        return;
    };
    if (pane.kind == .devices) if (self.devices) |devices| {
        if (self.plug) |plug| if (devices.answered and !devices.refused) {
            try shell_plug.draw(table, theme, body, devices, plug);
            return drawFaults(self, table, theme, shell_plug.rowsRect(body), devices);
        };
        if (devices.answered and devices.note() == null) {
            try shell_devices.draw(table, theme, body, devices);
            return drawFaults(self, table, theme, body, devices);
        }
    };
    if (pane.kind == .camera) if (self.camera) |camera| {
        try shell_camera.drawPreview(list, theme, toList(body), camera);
        if (self.camera_file) |file| return shell_camera_file.draw(table, theme, toList(body), camera, file);
        return shell_camera.draw(table, theme, toList(body), camera);
    };
    if (try drawMono(self, list, theme, pane, body)) return;
    if (pane.kind == .disasm) if (self.code) |pair| {
        const model = pair.of(pane.core);
        if (model.now) |*read| {
            const marks = if (self.breaks) |breaks| breaks.marks(pane.core) else null;
            return drawCode(table, theme, body, model.from, read, marks);
        }
    };
    if (pane.kind == .stack) if (self.stack) |pair| {
        if (pair.of(pane.core).now) |*now| {
            const chosen = if (self.locals) |locals| locals.of(pane.core).frame else 0;
            return stack_pane.draw(table, theme, toList(body), now, @intCast(chosen));
        }
    };
    if (pane.kind == .locals) if (self.locals) |pair| {
        if (pair.of(pane.core).now) |*now| return locals_pane.draw(list, theme, toList(body), now);
    };
    if (pane.kind == .map) if (self.map) |map| {
        if (map.layout) |*l| return map_pane.draw(list, theme, toList(body), l, map.hover);
    };
    if (pane.kind == .source) if (self.source) |pair| {
        const model = pair.of(pane.core);
        if (model.now) |*now| return source_pane.draw(table, theme, toList(body), now, &model.marks);
    };
    if (pane.kind == .board) if (self.board) |board| {
        const pressed = if (self.board_input) |pointer| pointer.press.held else null;
        if (!board_pane.Layout.of(toList(body), board.parts).board.empty()) return board_pane.draw(list, theme, toList(body), board.view(pressed), board.parts);
        // A leaf too small for the board still shows the panel by itself.
        if (board.hasFrame()) return list.image(fit.fitIn(toList(body), board.width, board.height), board.image());
    };
    if (pane.kind == .diff) if (self.diff) |diff_view| {
        return diff_pane.draw(table, theme, toList(body), diff_view);
    };
    if (pane.kind == .branches) if (self.branches) |feed| {
        if (feed.note() == null) return branch_tree.draw(table, theme, toList(body), feed.state.items());
    };
    const note = noteFor(self, pane) orelse return;
    const at = noteAt(body) orelse return;
    try font.draw(list, at.x, at.y, font.fit(note, at.room), theme.muted);
}

/// The fault cells over a listed devices leaf's rows, when the shell keeps faults.
fn drawFaults(self: *const Panes, table: *const widget.types.Paint, theme: *const Theme, rows: Rect, devices: *const shell_devices.Devices) !void {
    const faults = self.faults orelse return;
    if (devices.note() != null) return;
    try shell_fault.draw(table, theme, rows, devices, faults);
}

/// Instructions decoded forward from `pc` out of the rows read around it,
/// with `marks` drawing the run-to points when the shell keeps them
/// (RA8EMU-1171).
fn drawCode(table: *const widget.types.Paint, theme: *const Theme, body: Rect, pc: u32, read: *const shell_memory.Snapshot, marks: ?[]const u32) void {
    return disasm_pane.draw(table, theme, toList(body), &codeSnapshotFrom(pc, read, body), marks orelse &.{});
}

/// The snapshot a code leaf shows (RA8EMU-1171): decoded forward from
/// `pc` out of the rows read around it. The run-to point's click path
/// shares it, so a click lands on the line the pane drew.
pub fn codeSnapshotFrom(pc: u32, read: *const shell_memory.Snapshot, body: Rect) disasm_pane.Snapshot {
    const length = read.count * memory_pane.per_row;
    return disasm_capture.decodeRead(pc, read.base, read.bytes[0..length], read.readable[0..length], disasm_pane.rows(toList(body)));
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
    if (pane.kind == .locals) if (self.locals) |pair| {
        if (pair.of(pane.core).note()) |note| return note;
    };
    if (pane.kind == .source) if (self.source) |pair| {
        if (pair.of(pane.core).note()) |note| return note;
    };
    if (pane.kind == .branches) if (self.branches) |feed| {
        if (feed.note()) |note| return note;
    };
    return waitingFor(pane.kind);
}
