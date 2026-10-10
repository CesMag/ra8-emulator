//! The camera panel as one pane a window loop drives (RA8EMU-500): the
//! window's events go in, the panel is drawn into the frame, and between
//! emulation steps the CEU's source follows whatever the panel picked.
//!
//! It joins camera_view (drawing and clicks), camera_open (pick to source)
//! and camera_switch (swap in place) so the host shell needs three calls:
//! `handle` per event, `draw` per frame, `settle` between steps. It sees
//! only the platform seam's events, so the SDL window and the headless
//! one drive it the same way.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const platform = @import("platform.zig");
const camera_panel = @import("camera_panel.zig");
const source_spec = @import("ra8_host").camera.source_spec;
const camera_view = @import("ui/camera_view.zig");
const camera_open = @import("camera_open.zig");
const camera_switch = @import("camera_switch.zig");
const camera_devices = @import("camera_devices.zig");
const device_row = @import("ui/camera_device_row.zig");
const media_row = @import("ui/camera_media_row.zig");
const FrameSource = camera_switch.FrameSource;
const SourceSwap = @import("source_swap.zig").SourceSwap;

/// The button number SDL gives the primary (left) mouse button.
pub const primary_button: u8 = 1;

pub const Pane = struct {
    layout: camera_view.Layout,
    panel: camera_panel.Panel = .{},
    args: camera_open.Args = .{},
    switcher: camera_switch.Switcher = .{},
    /// The host's webcams, owned by whoever listed them; empty shows no row.
    devices: []const u32 = &.{},
    /// The webcam the device row picked; null opens the default one.
    device: ?u32 = null,
    /// The project's pictures and clips, owned by whoever listed them.
    pictures: []const []const u8 = &.{},
    clips: []const []const u8 = &.{},

    /// Starts the pane on the source the run was given (`--camera-source`)
    /// so it shows what the CEU already captures (RA8EMU-680). That source
    /// is open already, so nothing counts as a switch. A webcam the run
    /// opened was allowed on the terminal first, so it shows as allowed
    /// once: picking another source and coming back asks again.
    pub fn seed(self: *Pane, given: source_spec.Spec) void {
        switch (given.kind) {
            .gradient => {},
            .image => self.args.image = given.arg,
            .video => self.args.video = given.arg,
            .pipe => self.args.pipe = given.arg,
            .webcam => self.args.webcam = given.arg,
        }
        self.panel.active = given.kind;
    }

    /// Feeds one window event to the panel. Only a primary-button press is
    /// a click; returns whether the panel took the event, so the window
    /// does not also hand it to the board under the pane.
    pub fn handle(self: *Pane, event: platform.Event) bool {
        const press = switch (event) {
            .button => |button| button,
            else => return false,
        };
        if (!press.down or press.button != primary_button) return false;
        if (camera_view.click(&self.panel, self.layout, press.x, press.y)) return true;
        const picked = device_row.hit(device_row.Row.under(self.layout), self.devices, press.x, press.y);
        if (picked) |device| {
            self.pickDevice(device);
            return true;
        }
        const name = media_row.hit(self.mediaRow(), self.media(), press.x, press.y) orelse return false;
        self.pickMedia(name);
        return true;
    }

    /// The files the media row offers: the active source's kind, or none
    /// when the active source does not open a file.
    pub fn media(self: *const Pane) []const []const u8 {
        return switch (self.panel.active) {
            .image => self.pictures,
            .video => self.clips,
            else => &.{},
        };
    }

    /// Makes `name` the active picture or clip source's file; a new file
    /// counts as a switch so `settle` opens it.
    pub fn pickMedia(self: *Pane, name: []const u8) void {
        const slot = switch (self.panel.active) {
            .image => &self.args.image,
            .video => &self.args.video,
            else => return,
        };
        if (std.mem.eql(u8, slot.*, name)) return;
        slot.* = name;
        self.panel.changes += 1;
    }

    fn mediaRow(self: *const Pane) device_row.Row {
        return media_row.rowFor(self.layout, self.devices.len);
    }

    /// Names the webcam to open. While the webcam is running, the new
    /// device counts as a switch so `settle` reopens it.
    pub fn pickDevice(self: *Pane, device: u32) void {
        if (self.device != null and self.device.? == device) return;
        self.device = device;
        if (self.panel.active == .webcam) self.panel.changes += 1;
    }

    pub fn draw(self: *const Pane, list: *draw_list.DrawList) !void {
        try camera_view.draw(list, self.layout, self.panel);
        try device_row.draw(list, device_row.Row.under(self.layout), self.devices, self.device);
        const color = camera_view.colorOf(self.panel.active);
        try media_row.draw(list, self.mediaRow(), self.media(), self.args.of(self.panel.active), color);
    }

    /// Between emulation steps: when the panel switched, open its pick and
    /// put it where `source` points. A pick that will not open (nothing
    /// chosen yet, a file that will not read) leaves the running source.
    pub fn settle(
        self: *Pane,
        allocator: std.mem.Allocator,
        io: std.Io,
        source: *FrameSource,
        format_control: *const u8,
    ) void {
        const changes = self.panel.changes;
        const next = self.openPick(allocator, io, format_control) orelse return;
        self.switcher.apply(source, next, changes);
    }

    /// While the engine runs on (RA8EMU-227): open the pick here and post
    /// it, for the engine to install at its next park.
    pub fn settleInto(
        self: *Pane,
        allocator: std.mem.Allocator,
        io: std.Io,
        swap: *SourceSwap,
        format_control: *const u8,
    ) void {
        const changes = self.panel.changes;
        const next = self.openPick(allocator, io, format_control) orelse return;
        swap.post(next);
        self.switcher.posted(changes);
    }

    /// The panel's pick, opened, when it switched since the last one.
    fn openPick(self: *Pane, allocator: std.mem.Allocator, io: std.Io, format_control: *const u8) ?FrameSource {
        const changes = self.panel.changes;
        if (!self.switcher.due(changes)) return null;
        var args = self.args;
        var device_buf: [4]u8 = undefined;
        if (self.device) |device| args.webcam = camera_devices.argument(&device_buf, device) catch unreachable;
        return camera_open.open(allocator, io, self.panel, args, format_control) catch {
            self.switcher.skip(changes);
            return null;
        };
    }
};
