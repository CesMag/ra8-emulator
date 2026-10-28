//! The host half of a USB/IP connection with the host taken away (row 24):
//! recorded commands are fed to a session of their own and its replies go
//! nowhere. The replay drives the device exactly as the live bridge did,
//! one poll at a time: the commands recorded at a poll first, then one
//! pump of the URBs in flight when the connection was already up at the
//! start of that poll.
const std = @import("std");
const session = @import("session.zig");
const usbfs = @import("ra8_chip").periph.usbfs;
const traffic = @import("ra8_board").usb.traffic;

pub const Replayer = struct {
    urbs: session.Session = .{},
    /// A host is imported.
    connected: bool = false,
    /// The host was imported when the poll began, so this poll pumps.
    armed: bool = false,

    /// Applies one recorded event. Every reply the device's answers would
    /// have sent is discarded.
    pub fn feed(self: *Replayer, device: *usbfs.Device, event: traffic.Event) !void {
        switch (event.kind) {
            .import => {
                self.urbs = .{};
                self.connected = true;
            },
            .submit, .unlink => {
                if (!self.connected) return error.NotImported;
                try self.command(event);
            },
            .disconnect => {
                if (event.pumped) self.pump(device);
                self.urbs = .{};
                self.connected = false;
            },
        }
    }

    /// Ends a poll: pumps when the host was there at its start.
    pub fn settle(self: *Replayer, device: *usbfs.Device) void {
        if (self.armed and self.connected) self.pump(device);
        self.armed = self.connected;
    }

    fn command(self: *Replayer, event: traffic.Event) !void {
        var raw: [traffic.header_len + traffic.max_data]u8 = undefined;
        const total = event.head.len + event.data.len;
        if (total > raw.len) return error.TooLong;
        @memcpy(raw[0..event.head.len], event.head);
        @memcpy(raw[event.head.len..total], event.data);
        var reader: std.Io.Reader = .fixed(raw[0..total]);
        var muted: std.Io.Writer.Discarding = .init(&.{});
        if (!try self.urbs.receive(&reader, &muted.writer)) return error.NotImported;
    }

    fn pump(self: *Replayer, device: *usbfs.Device) void {
        var muted: std.Io.Writer.Discarding = .init(&.{});
        _ = self.urbs.pump(device, &muted.writer) catch {};
    }
};
