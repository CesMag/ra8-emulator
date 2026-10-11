//! Tests for src/interfaces/gui/shell/board/input.zig (RA8EMU-1119): a click
//! on a switch of the shell's board leaf reaches the firmware of an
//! in-process session, a release elsewhere sends nothing, a press off the
//! board is not taken, and a tap or a drag on the panel image sends one
//! touch gesture.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const Rig = @import("../../local_rig.zig").Rig;

const proto = ra8.rpc.session.rpc;
const draw_list = ra8.render.draw_list;
const pane_layout = gui_app.pane_layout;
const frame = gui_app.shell.frame;
const board_pane = gui_app.board_pane;
const board_touch = gui_app.board.touch;
const shell_board_input = gui_app.shell.board.input;
const Board = gui_app.shell.board.Board;
const Pointer = shell_board_input.Pointer;
const Rect = draw_list.Rect;

/// Mirrors SW1 onto LED1 (tests/fixtures/gpio/README.md).
const image = "tests/fixtures/gpio/buttons.elf";
const width = 640;
const height = 480;

const Bench = struct {
    rig: Rig,
    board: Board,
    pointer: Pointer = .{},
    layout: pane_layout.Layout,
    solved: pane_layout.Solved,
    /// The board leaf's body and the parts laid out in it.
    body: Rect,
    parts: board_pane.Layout,
    /// Board time at the end of the last advance.
    now_ns: u64 = 0,
    /// Inputs the session has scheduled, and requests it has refused.
    scheduled: u32 = 0,
    refused: u32 = 0,

    fn open(self: *Bench) !void {
        const gpa = std.testing.allocator;
        try self.rig.open(image);
        self.board = Board.init(gpa);
        self.pointer = .{};
        self.layout = try pane_layout.twoCore(gpa);
        self.solved = try frame.solve(&self.layout, gpa, width, height);
        self.now_ns = 0;
        self.scheduled = 0;
        self.refused = 0;
        self.body = for (self.solved.panes.items) |placed| {
            const pane = self.layout.pane(placed.index) orelse continue;
            if (pane.kind == .board) break frame.bodyOf(placed.area);
        } else return error.NoBoardLeaf;
        self.parts = board_pane.Layout.of(self.body);
        self.board.attach(&self.rig.link);
        try self.exchange();
        try std.testing.expectEqual(@as(u32, 0), self.refused);
    }

    fn deinit(self: *Bench) void {
        const gpa = std.testing.allocator;
        self.solved.deinit(gpa);
        self.layout.deinit();
        self.board.deinit();
        self.rig.deinit();
    }

    /// Let the session answer, and take what it sent.
    fn exchange(self: *Bench) !void {
        try self.rig.session.answer();
        while (self.rig.link.pump()) |arrival| {
            try self.board.observe(arrival);
            switch (arrival) {
                .response => |response| switch (response.result) {
                    .err => self.refused += 1,
                    .ok => |bytes| if (proto.decode(proto.Advanced, bytes)) |done| {
                        self.now_ns = done.to_ns;
                    } else |_| {},
                },
                .event => |event| if (event.topic == @backingInt(proto.Topic.session)) {
                    const sent = try proto.decode(proto.SessionEvent, event.payload);
                    if (sent.kind == .input_scheduled) self.scheduled += 1;
                },
            }
        }
    }

    /// Run the image for `ns` of board time.
    fn advance(self: *Bench, ns: u64) !void {
        _ = try self.rig.link.send(proto.Advance, .advance, .{ .core = .cpu0, .ns = ns });
        try self.exchange();
    }

    fn down(self: *Bench, x: i32, y: i32) bool {
        return self.pointer.down(&self.board, &self.layout, &self.solved, x, y, self.now_ns);
    }

    fn up(self: *Bench, x: i32, y: i32) !void {
        self.pointer.up(&self.board, &self.rig.link, x, y, self.now_ns);
        try self.exchange();
    }

    /// Give the board a panel of `w` by `h` pixels, as its first frame would.
    fn panel(self: *Bench, comptime w: u16, comptime h: u16) !void {
        var bytes: [64 + @as(usize, w) * h]u8 = undefined;
        const pixels: [@as(usize, w) * h]u8 = @splat(128);
        const payload = try proto.encode(proto.DirtyRect, .{ .core = .cpu0, .x = 0, .y = 0, .width = w, .height = h, .virtual_ns = 0, .pixels = &pixels }, &bytes);
        try self.board.observe(.{ .event = .{ .topic = @backingInt(proto.Topic.lcd_dirty), .payload = payload } });
    }
};

fn centre(area: Rect) struct { x: i32, y: i32 } {
    return .{ .x = area.x + @divTrunc(area.w, 2), .y = area.y + @divTrunc(area.h, 2) };
}

test "a click on SW1 of the board leaf reaches the firmware, which lights LED1" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.deinit();
    try bench.advance(2_000);
    try std.testing.expect(!bench.board.leds.on[0]);

    const at = centre(bench.parts.switches[0]);
    try std.testing.expect(bench.down(at.x, at.y));
    try std.testing.expectEqual(@as(?usize, 0), bench.pointer.press.held);
    try std.testing.expectEqual(@as(?Rect, bench.body), bench.pointer.grabbed);
    try bench.up(at.x, at.y);
    try std.testing.expectEqual(@as(?Rect, null), bench.pointer.grabbed);
    try std.testing.expectEqual(@as(u32, 1), bench.scheduled);
    try std.testing.expectEqual(@as(u32, 0), bench.refused);

    for (0..8) |_| {
        if (bench.board.leds.on[0]) break;
        try bench.advance(20_000);
    }
    try std.testing.expect(bench.board.leds.on[0]);
}

test "a release off the switch the press began on sends nothing" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.deinit();
    const sw1 = centre(bench.parts.switches[0]);
    const sw2 = centre(bench.parts.switches[1]);
    try std.testing.expect(bench.down(sw1.x, sw1.y));
    try bench.up(sw2.x, sw2.y);
    try std.testing.expectEqual(@as(?usize, null), bench.pointer.press.held);
    try std.testing.expectEqual(@as(u32, 0), bench.scheduled);
    // A release with nothing held is not the board's either.
    try bench.up(sw1.x, sw1.y);
    try std.testing.expectEqual(@as(u32, 0), bench.scheduled);
}

test "a press off every board leaf, or on the bare board, is not taken" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.deinit();
    for (bench.solved.panes.items) |placed| {
        const pane = bench.layout.pane(placed.index) orelse continue;
        if (pane.kind == .board) continue;
        const at = centre(frame.bodyOf(placed.area));
        try std.testing.expect(!bench.down(at.x, at.y));
    }
    // With no frame yet the panel is not a touch surface.
    const slot = centre(bench.parts.panel);
    try std.testing.expect(!bench.down(slot.x, slot.y));
    try std.testing.expectEqual(@as(?Rect, null), bench.pointer.grabbed);
    try std.testing.expectEqual(@as(?Rect, null), shell_board_input.bodyAt(&bench.layout, &bench.solved, -1, -1));
}

test "a tap on the panel image sends one touch, and a drag one swipe" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.deinit();
    try bench.panel(8, 4);
    const shown = board_touch.shownIn(bench.parts, 8, 4);
    const mid = centre(shown);
    try std.testing.expect(bench.down(mid.x, mid.y));
    try std.testing.expectEqual(@as(?usize, null), bench.pointer.press.held);
    try bench.up(mid.x, mid.y);
    try std.testing.expectEqual(@as(u32, 1), bench.scheduled);
    try std.testing.expectEqual(@as(u32, 0), bench.refused);

    try std.testing.expect(bench.down(shown.x + 1, mid.y));
    bench.pointer.move(&bench.board, shown.x + shown.w - 1, mid.y);
    try std.testing.expectEqual(@as(u16, 7), bench.pointer.drag.last.x);
    // The release may land outside the image: the gesture ends at its edge.
    try bench.up(shown.x + shown.w + 40, mid.y);
    try std.testing.expectEqual(@as(u32, 2), bench.scheduled);
    try std.testing.expectEqual(@as(u32, 0), bench.refused);
}
