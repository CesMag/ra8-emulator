//! `--usbip PORT` (RA8EMU-75 slice 4d): the live bridge rides the board's
//! USB tick, so it is polled at every boundary on both backends while the
//! firmware runs. It binds once the FS device has enumerated, serves the
//! host that imports it, and keeps listening after that host leaves.
//! Its events go to stderr, beside the gdb listener's.
const std = @import("std");
const usb = @import("ra8_board").usb;
const usbfs = @import("ra8_chip").periph.usbfs;
const bridge = @import("bridge.zig");

pub const Live = struct {
    link: bridge.Bridge,
    stopped: bool = false,

    fn poll(context: *anyopaque, device: *usbfs.Device, script: *const usbfs.host.Host) void {
        const self: *Live = @ptrCast(@alignCast(context));
        if (self.stopped) return;
        var stderr = std.Io.File.stderr().writerStreaming(self.link.io, &.{});
        const out = &stderr.interface;
        const event = self.link.poll(device, script) catch |err| {
            self.stopped = true;
            out.print("usbip: the bridge stopped ({s})\n", .{@errorName(err)}) catch {};
            return;
        };
        report(out, event, &self.link) catch {};
    }
};

/// Put a bridge on the board's USB tick when `port` is set. The bridge
/// lives as long as `allocator`; the run's arena outlives the run.
pub fn install(target: *usb.Usb, allocator: std.mem.Allocator, io: std.Io, port: ?u16) !void {
    const wanted = port orelse return;
    const live = try allocator.create(Live);
    live.* = .{ .link = try bridge.Bridge.init(allocator, io, wanted) };
    target.bridge = .{ .context = live, .pollFn = Live.poll };
}

/// One line for each event that changed something a user would see.
pub fn report(out: anytype, event: bridge.Event, link: *const bridge.Bridge) !void {
    switch (event) {
        .none => {},
        .listening => {
            const item = link.exported().?;
            try out.print("usbip: exporting {s} ({x:0>4}:{x:0>4}) on 127.0.0.1:{d}\n", .{ item.device.busid, item.device.vendor, item.device.product, link.port().? });
        },
        .attached => try out.print("usbip: a host imported {s}\n", .{link.exported().?.device.busid}),
        .hung_up => try out.print("usbip: the host detached; still listening on 127.0.0.1:{d}\n", .{link.port().?}),
        .unusable => try out.print("usbip: the FS device's descriptors are unusable; nothing exported\n", .{}),
    }
}
