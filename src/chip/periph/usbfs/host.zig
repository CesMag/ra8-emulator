//! The host on the far end of the USBFS jack, scripted: it takes a device
//! the pull-up attached through standard enumeration, one step per chunk
//! boundary, the way a PC would.
//!
//! Each step sends its SETUP through Device.setup, collects any IN data the
//! driver commits on the DCP, and waits for the driver to end the status
//! stage with CCPL before moving on. SET_ADDRESS needs no wait: the SIE
//! answers it. A step that takes longer than `patience` boundaries ends the
//! script in `failed`, so a driver that never answers cannot hold it forever.
const std = @import("std");
const usbfs = @import("usbfs.zig");
const regs = @import("../usbhs/regs.zig");

pub const Step = enum {
    waiting,
    device_descriptor,
    set_address,
    config_descriptor,
    full_config,
    set_configuration,
    get_configuration,
    get_status,
    string_languages,
    string_product,
    set_interface,
    set_halt,
    clear_halt,
    configured,
    failed,
};

/// How the device ended a no-data request: CCPL, or a STALL on the DCP.
pub const Answer = enum { none, ack, stall };

pub const requests = struct {
    pub const address: u8 = 1;
    pub const device_descriptor = [8]u8{ 0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x12, 0x00 };
    pub const set_address = [8]u8{ 0x00, 0x05, address, 0x00, 0x00, 0x00, 0x00, 0x00 };
    pub const config_descriptor = [8]u8{ 0x80, 0x06, 0x00, 0x02, 0x00, 0x00, 0x09, 0x00 };
    /// GET_DESCRIPTOR(Configuration) for `length` bytes: the whole set once
    /// the first nine have said how long it is.
    pub fn configDescriptor(length: u16) [8]u8 {
        return .{ 0x80, 0x06, 0x00, 0x02, 0x00, 0x00, @truncate(length), @truncate(length >> 8) };
    }
    pub const set_configuration = [8]u8{ 0x00, 0x09, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00 };
    pub const get_configuration = [8]u8{ 0x80, 0x08, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00 };
    /// SET_INTERFACE(alternate 0, interface 0): every configured device
    /// has interface 0, and a device with no alternates may STALL it.
    pub const set_interface = [8]u8{ 0x01, 0x0B, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    /// SET_FEATURE or CLEAR_FEATURE(ENDPOINT_HALT) on `endpoint`.
    pub fn endpointHalt(set: bool, endpoint: u8) [8]u8 {
        return .{ 0x02, if (set) 0x03 else 0x01, 0x00, 0x00, endpoint, 0x00, 0x00, 0x00 };
    }
    pub const get_status = [8]u8{ 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00 };
    /// GET_DESCRIPTOR(String) `index` in `language`, for up to 255 bytes; the
    /// device ends it early with a short packet. Index 0 is the language list.
    pub fn stringDescriptor(index: u8, language: u16) [8]u8 {
        return .{ 0x80, 0x06, index, 0x03, @truncate(language), @truncate(language >> 8), 0xFF, 0x00 };
    }
};

/// The control endpoint's packet size: a packet shorter than this ends a read.
pub const max_packet: usize = 64;

pub const Host = struct {
    step: Step = .waiting,
    /// The step the script was on when it ended in failed, for the report.
    failed_on: Step = .waiting,
    /// Whether the current step's SETUP has gone out.
    sent: bool = false,
    /// Whether the current step's status-stage token has gone out.
    acked: bool = false,
    /// Boundaries spent on the current step, and how many it may take.
    waited: u32 = 0,
    patience: u32 = 20_000,
    /// What the device returned, for the run report.
    device: [18]u8 = @splat(0),
    /// The configuration descriptor set, as much of it as fits; config_len
    /// is how much of it the full read asked for, 0 until then.
    config: [255]u8 = @splat(0),
    config_len: u16 = 0,
    /// GET_CONFIGURATION's one byte and GET_STATUS's two, once configured.
    config_value: [1]u8 = .{0},
    status: [2]u8 = .{ 0, 0 },
    /// Set to stall when the device refused GET_CONFIGURATION or GET_STATUS.
    config_answer: Answer = .none,
    status_answer: Answer = .none,
    /// String descriptor 0 (the language IDs) and the iProduct string, as sent.
    languages: [255]u8 = @splat(0),
    product: [255]u8 = @splat(0),
    /// How the device answered SET_INTERFACE.
    interface: Answer = .none,
    /// How the device answered halting, then un-halting, its first endpoint.
    halt_set: Answer = .none,
    halt_clear: Answer = .none,
    got: u16 = 0,
    /// Whether the current read ended on a short packet.
    short: bool = false,

    pub fn tick(self: *Host, device: *usbfs.Device) void {
        switch (self.step) {
            .waiting => if (state(device) == usbfs.intsts0.dvsq_default) self.advance(.device_descriptor),
            .device_descriptor => self.read(device, requests.device_descriptor, &self.device, .set_address),
            .set_address => {
                device.setup(requests.set_address);
                self.advance(.config_descriptor);
            },
            .config_descriptor => self.read(device, requests.config_descriptor, self.config[0..9], .full_config),
            .full_config => self.readAll(device),
            .set_configuration => if (self.write(device, requests.set_configuration)) |answer|
                self.advance(if (answer == .ack) .get_configuration else .failed),
            .get_configuration => self.read(device, requests.get_configuration, &self.config_value, .get_status),
            .get_status => self.read(device, requests.get_status, &self.status, .string_languages),
            .string_languages => self.readLanguages(device),
            .string_product => self.readProduct(device),
            .set_interface => if (self.write(device, requests.set_interface)) |answer| {
                self.interface = answer;
                self.advance(if (firstEndpoint(self.configuration()) != null) .set_halt else .configured);
            },
            .set_halt => if (self.write(device, requests.endpointHalt(true, self.endpoint()))) |answer| {
                self.halt_set = answer;
                self.advance(.clear_halt);
            },
            .clear_halt => if (self.write(device, requests.endpointHalt(false, self.endpoint()))) |answer| {
                self.halt_clear = answer;
                self.advance(.configured);
            },
            .configured, .failed => {},
        }
    }

    /// The configuration descriptor bytes the host holds: the full set once
    /// it has been read, the first nine before that.
    pub fn configuration(self: *const Host) []const u8 {
        return self.config[0..if (self.config_len != 0) self.config_len else 9];
    }

    /// The second configuration read, for wTotalLength bytes (capped at the
    /// buffer). The length is taken once, from the header, before the read
    /// starts overwriting it. A set no longer than its header needs no
    /// second read.
    fn readAll(self: *Host, device: *usbfs.Device) void {
        if (self.config_len == 0) {
            const declared = std.mem.readInt(u16, self.config[2..4], .little);
            self.config_len = @intCast(@min(declared, self.config.len));
        }
        const total = self.config_len;
        if (total <= 9) return self.advance(.set_configuration);
        self.read(device, requests.configDescriptor(self.config_len), self.config[0..total], .set_configuration);
    }

    /// String descriptor 0, only from a device that names a string. One
    /// whose iManufacturer, iProduct and iSerialNumber are all 0 has no
    /// strings at all (USB 2.0 9.6.7) and may stall the request.
    fn readLanguages(self: *Host, device: *usbfs.Device) void {
        if (std.mem.allEqual(u8, self.device[14..17], 0)) return self.advance(.set_interface);
        self.read(device, requests.stringDescriptor(0, 0), &self.languages, .string_product);
    }

    /// The iProduct string in the device's first language; a device that
    /// names no product, or lists no language, has nothing to read.
    fn readProduct(self: *Host, device: *usbfs.Device) void {
        const index = self.device[15];
        if (index == 0 or self.languages[0] < 4) return self.advance(.set_interface);
        const language = std.mem.readInt(u16, self.languages[2..4], .little);
        self.read(device, requests.stringDescriptor(index, language), &self.product, .set_interface);
    }

    /// The endpoint the halt requests aim at: the first one the set lists.
    fn endpoint(self: *const Host) u8 {
        return firstEndpoint(self.configuration()) orelse 0;
    }

    pub fn done(self: *const Host) bool {
        return self.step == .configured;
    }

    fn advance(self: *Host, next: Step) void {
        if (next == .failed) self.failed_on = self.step;
        self.step = next;
        self.sent = false;
        self.acked = false;
        self.waited = 0;
        self.got = 0;
        self.short = false;
    }

    fn patient(self: *Host) bool {
        self.waited += 1;
        if (self.waited <= self.patience) return true;
        self.failed_on = self.step;
        self.step = .failed;
        return false;
    }

    /// A control read: SETUP, IN packets until the requested length is in or
    /// a short packet ends it, the OUT status token on the next boundary,
    /// then the driver's CCPL.
    fn read(self: *Host, device: *usbfs.Device, packet: [8]u8, into: []u8, next: Step) void {
        if (!self.send(device, packet)) return;
        if (!self.patient()) return;
        if (stalled(device)) return self.refused(next);
        var chunk: [max_packet]u8 = undefined;
        if (device.control.hostTake(&chunk)) |len| {
            const n = @min(len, into.len - self.got);
            @memcpy(into[self.got..][0..n], chunk[0..n]);
            self.got += n;
            if (len < max_packet) self.short = true;
        }
        if (self.got < into.len and !self.short) return;
        if (!self.acked) {
            device.statusStage();
            self.acked = true;
            return;
        }
        if (idle(device)) self.advance(next);
    }

    /// GET_CONFIGURATION, GET_STATUS and the string reads are probes: a
    /// device may STALL them, and the host notes it and moves on. A STALL
    /// on a descriptor read the host needs ends the script.
    fn refused(self: *Host, next: Step) void {
        switch (self.step) {
            .get_configuration => self.config_answer = .stall,
            .get_status => self.status_answer = .stall,
            .string_languages, .string_product => {},
            else => return self.advance(.failed),
        }
        self.advance(next);
    }

    /// A no-data request: SETUP, then the driver's CCPL or a STALL. Null
    /// while the driver has done neither; the caller picks the next step.
    fn write(self: *Host, device: *usbfs.Device, packet: [8]u8) ?Answer {
        if (!self.send(device, packet)) return null;
        if (!self.patient()) return null;
        if (idle(device)) return .ack;
        if (stalled(device)) return .stall;
        return null;
    }

    /// True once the SETUP is out; the boundary that sends it does nothing else.
    fn send(self: *Host, device: *usbfs.Device, packet: [8]u8) bool {
        if (self.sent) return true;
        device.setup(packet);
        self.sent = true;
        return false;
    }
};

fn state(device: *const usbfs.Device) u16 {
    return device.interruptStatus() & usbfs.intsts0.dvsq_mask;
}

/// The bEndpointAddress of the first endpoint descriptor in a configuration
/// set, walking descriptors by bLength; null when it lists none.
pub fn firstEndpoint(set: []const u8) ?u8 {
    var at: usize = 0;
    while (at + 2 < set.len) {
        const length = set[at];
        if (length < 2) return null;
        if (set[at + 1] == 5 and at + 2 < set.len) return set[at + 2];
        at += length;
    }
    return null;
}

fn stalled(device: *usbfs.Device) bool {
    return device.read(usbfs.window.base + regs.reg.dcpctr, 2) & regs.dcpctr.pid_stall != 0;
}

fn idle(device: *const usbfs.Device) bool {
    return device.interruptStatus() & usbfs.intsts0.ctsq_mask == usbfs.intsts0.ctsq_idle;
}
