//! The board's USB side: which controller this board drives and what is on
//! the far end of it.
//!
//! The EK-RA8D2 has two USB jacks, and the self-loop apps cable them to each
//! other: this controller is the host half of that loop. Whether a device is
//! on the other end is a board fact, so it is set here. The device jack has
//! a scripted host on it, the way a PC would be, stepped once per boundary.
const std = @import("std");
const Bounded = @import("ra8_chip").core.bounded.Bounded;
const periph = @import("ra8_chip").periph.registry;
const usbfs = @import("ra8_chip").periph.usbfs;
const usbhs = @import("ra8_chip").periph.usbhs;
const usb_echo = @import("../components/usb_echo/device.zig");
const usb_echo_far = @import("../components/usb_echo/far.zig");
const usb_loop_cable = @import("../components/usb_loop_cable/cable.zig");
const usb_stick = @import("../components/usb_stick/stick.zig");

pub const Due = Bounded(u16, 1);

pub const event = struct {
    /// ELC_EVENT_USBFS_INT (ra8_elc_regs.h k_ra8_elc_event_usbfs_int).
    pub const usbfs_int: u16 = 0x09A;
};

/// Something outside the board polled on the device jack each boundary.
pub const Hook = struct {
    context: *anyopaque,
    pollFn: *const fn (*anyopaque, *usbfs.Device, *const usbfs.host.Host) void,
};

pub const Usb = struct {
    host: usbhs.Host = .{},
    /// The device half of the loop, with VBUS from the host jack.
    device: usbfs.Device = .{},
    /// The host on the device jack.
    script: usbfs.host.Host = .{},
    /// The cable between the two jacks, once `loopBack` laid it. With it in,
    /// the HS host talks to the firmware's own USBFS device, and the
    /// scripted host is unplugged: one jack carries one host.
    cable: ?usb_loop_cable.Loop = null,
    /// A usbip bridge (`--usbip`, RA8EMU-75), polled after the scripted
    /// host so it sees the device as the firmware has just left it.
    bridge: ?Hook = null,
    /// The device on the HS host jack while no cable is laid: it enumerates
    /// and echoes its bulk endpoint.
    echo: usb_echo.Device = .{},
    /// The USB stick, behind the echo device once a disk is plugged in
    /// (usb_plug.zig).
    stick: usb_stick.Target = .{},

    /// The board has to be at its final address: the host keeps a pointer to
    /// the echo device.
    pub fn attach(self: *Usb, bus: *periph.Bus) periph.Error!void {
        self.host.xfer.far = usb_echo_far.far(&self.echo);
        self.host.attachDevice();
        try bus.add(self.host.block());
        self.device.connectVbus();
        try bus.add(self.device.block());
    }

    /// Cable the HS host jack to the board's own FS device jack. The board
    /// has to be at its final address: both ends keep pointers into it.
    pub fn loopBack(self: *Usb) void {
        self.cable = .{ .device = &self.device };
        self.host.xfer.far = self.cable.?.far();
    }

    pub fn tick(self: *Usb) void {
        if (self.cable != null) return;
        self.script.tick(&self.device);
        if (self.bridge) |hook| hook.pollFn(hook.context, &self.device, &self.script);
    }

    /// USBFS_INT while the device's line is up, so a handler that returns
    /// with a cause still set is entered again, as on the level line.
    pub fn dueEvents(self: *const Usb) Due {
        var due = Due{};
        if (self.device.interruptLine()) due.appendAssumeCapacity(event.usbfs_int);
        return due;
    }

    pub fn quiet(self: *const Usb) bool {
        return self.host.quiet();
    }
};
