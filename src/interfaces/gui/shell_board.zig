//! The shell's board feed (RA8EMU-790, RA8EMU-1119): the panel image the
//! session streams as lcd_dirty rectangles of grayscale pixels (RA8EMU-789),
//! and the user LEDs it reports as led_changed events on the session topic
//! (RA8EMU-811). Once the link is connected it subscribes both for cpu0.
//! Each rectangle is copied into an RGBA image that grows to cover every
//! rectangle seen, and pixels no rectangle has reached yet stay black. The
//! LEDs need no panel, so an image with no LCD output still shows them.
const std = @import("std");
const proto = @import("ra8_rpc").session_rpc;
const session_link = @import("session_link.zig");
const draw_list = @import("ra8_render").draw_list;
const colors = @import("ui/colors.zig");
const board_pane = @import("ui/board_pane.zig");
const board_capture = @import("board_capture.zig");

const Color = draw_list.Color;
const unseen = colors.unseen;

pub const Board = struct {
    allocator: std.mem.Allocator,
    pixels: []Color = &.{},
    width: u32 = 0,
    height: u32 = 0,
    /// The user LEDs as the session last reported them.
    leds: board_pane.Leds = .{},
    subscribed: bool = false,

    pub fn init(allocator: std.mem.Allocator) Board {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Board) void {
        self.allocator.free(self.pixels);
    }

    /// Subscribe cpu0's panel changes and session events, once, after the
    /// session greets. A session with no display refuses the first and
    /// still sends the second.
    pub fn attach(self: *Board, link: *session_link.Link) void {
        if (self.subscribed or link.state != .connected) return;
        for ([_]proto.Topic{ .lcd_dirty, .session }) |topic| {
            _ = link.send(proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = topic }) catch return;
        }
        self.subscribed = true;
    }

    /// Copy an lcd_dirty rectangle into the image, or fold an LED change
    /// into the LEDs.
    pub fn observe(self: *Board, arrival: session_link.Arrival) error{OutOfMemory}!void {
        const event = switch (arrival) {
            .event => |event| event,
            .response => return,
        };
        if (event.topic == @backingInt(proto.Topic.session)) {
            const change = proto.decode(proto.SessionEvent, event.payload) catch return;
            if (change.core == .cpu0) board_capture.observe(&self.leds, change);
            return;
        }
        if (event.topic != @backingInt(proto.Topic.lcd_dirty)) return;
        const rect = proto.decode(proto.DirtyRect, event.payload) catch return;
        if (rect.core != .cpu0 or rect.pixels.len != @as(usize, rect.width) * rect.height) return;
        try self.cover(@as(u32, rect.x) + rect.width, @as(u32, rect.y) + rect.height);
        for (0..rect.height) |row| {
            const into = self.pixels[(rect.y + row) * self.width + rect.x ..][0..rect.width];
            for (into, rect.pixels[row * rect.width ..][0..rect.width]) |*pixel, gray| pixel.* = Color.rgb(gray, gray, gray);
        }
    }

    /// Whether any rectangle has arrived yet.
    pub fn hasFrame(self: *const Board) bool {
        return self.width != 0 and self.height != 0;
    }

    pub fn image(self: *const Board) draw_list.Image {
        return .{ .width = self.width, .height = self.height, .pixels = self.pixels };
    }

    /// What the board pane draws: the LEDs, the panel once a frame has
    /// arrived, and the switch the pointer holds down.
    pub fn view(self: *const Board, pressed: ?usize) board_pane.View {
        return .{ .leds = &self.leds, .panel = if (self.hasFrame()) self.image() else null, .pressed = pressed };
    }

    /// Grow the image to at least `width` by `height`, keeping what it holds.
    fn cover(self: *Board, width: u32, height: u32) error{OutOfMemory}!void {
        if (width <= self.width and height <= self.height) return;
        const wide = @max(width, self.width);
        const tall = @max(height, self.height);
        const grown = try self.allocator.alloc(Color, @as(usize, wide) * tall);
        @memset(grown, unseen);
        for (0..self.height) |row| {
            @memcpy(grown[row * wide ..][0..self.width], self.pixels[row * self.width ..][0..self.width]);
        }
        self.allocator.free(self.pixels);
        self.pixels = grown;
        self.width = wide;
        self.height = tall;
    }
};
