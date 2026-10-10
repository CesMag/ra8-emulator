//! What is on the far end of the cable: a device that answers the standard
//! requests a host enumerates with, and a bulk endpoint that echoes.
//!
//! dev bridged every SETUP to a second emulated part and answered whatever
//! came back, so an image could ask for a descriptor the device never had and
//! still be handed bytes. A real device stalls what it does not implement and
//! refuses what its state does not allow, which is what the host driver has
//! to cope with on a bench.
const regs = @import("ra8_chip").periph.usbhs_regs;
const setup = @import("ra8_chip").periph.usbhs_setup;
const usbhs_function = @import("ra8_chip").periph.usbhs_function;

/// Where enumeration has got to, per USB 2.0 chapter 9.
pub const State = enum { default, address, configured };

/// The device's own descriptors. Small on purpose: what a host reads to get
/// through enumeration, not a full device.
pub const descriptors = struct {
    pub const device = [_]u8{
        18,   0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 64,
        0x45, 0x04, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00,
        0x00, 0x01,
    };
    pub const configuration = [_]u8{
        9,    0x02, 0x20, 0x00, 0x01, 0x01, 0x00, 0x80, 50,
        9,    0x04, 0x00, 0x00, 0x02, 0x08, 0x06, 0x50, 0x00,
        7,    0x05, 0x81, 0x02, 0x00, 0x02, 0x00, 7,    0x05,
        0x02, 0x02, 0x00, 0x02, 0x00,
    };
};

/// The far end of the modelled cable.
pub const Device = struct {
    state: State = .default,
    address: u8 = 0,
    configuration: u8 = 0,

    /// What the device owes the host on the control pipe.
    reply: [regs.staging.reply_cap]u8 = @splat(0),
    reply_len: u16 = 0,
    reply_ready: bool = false,

    /// The bulk endpoint's loopback: what came in on OUT goes back out on IN.
    echo: [regs.staging.packet_cap]u8 = @splat(0),
    echo_len: u16 = 0,
    echo_ready: bool = false,

    /// The function behind the bulk endpoints. With one plugged in (the
    /// board plugs the USB stick here) the endpoints speak its protocol;
    /// without one they echo, as before.
    storage: ?usbhs_function.Function = null,

    setups: u32 = 0,
    /// Requests answered with a stall, each for its own reason.
    unsupported: u32 = 0,
    out_of_order: u32 = 0,
    /// The last SETUP was refused: what the host sees as its answer.
    stalled: bool = false,

    /// USBRST released: the device drops back to Default and forgets its
    /// address, the way silicon does.
    ///
    /// The endpoint goes with it. A device in Default has no endpoints but
    /// the control pipe, so a bulk packet this one was holding when the
    /// reset came cannot be answered afterwards: the endpoint that owed it
    /// stopped existing. Leaving it staged hands the next host to arm that
    /// pipe a packet from before the reset, on a device that has not been
    /// configured since.
    pub fn busReset(self: *Device) void {
        self.state = .default;
        self.address = 0;
        self.configuration = 0;
        self.reply_len = 0;
        self.reply_ready = false;
        self.echo_len = 0;
        self.echo_ready = false;
        if (self.storage) |function| function.reset();
    }

    /// Answer a SETUP. False means the device stalled it, which is what the
    /// host sees as a failed control transfer.
    pub fn handle(self: *Device, packet: setup.Packet) bool {
        self.setups += 1;
        return switch (packet.code) {
            setup.request.get_descriptor => self.describe(packet),
            setup.request.set_address => self.takeAddress(packet),
            setup.request.set_configuration => self.configure(packet),
            setup.request.get_configuration => self.stage(&[_]u8{self.configuration}, packet.length),
            setup.request.get_status => self.stage(&[_]u8{ 0, 0 }, packet.length),
            else => {
                self.unsupported += 1;
                return false;
            },
        };
    }

    fn describe(self: *Device, packet: setup.Packet) bool {
        return switch (packet.descriptorType()) {
            setup.descriptor.device => self.stage(&descriptors.device, packet.length),
            setup.descriptor.configuration => self.stage(&descriptors.configuration, packet.length),
            else => {
                self.unsupported += 1;
                return false;
            },
        };
    }

    /// A device takes an address from Default or Address, never once it is
    /// configured.
    fn takeAddress(self: *Device, packet: setup.Packet) bool {
        if (self.state == .configured) {
            self.out_of_order += 1;
            return false;
        }
        self.address = packet.requestedAddress();
        self.state = if (self.address == 0) .default else .address;
        return true;
    }

    /// A configuration means nothing until the device has an address: dev
    /// took one straight out of Default, so an image that skipped
    /// SET_ADDRESS enumerated anyway in the emulator and hung on the bench.
    fn configure(self: *Device, packet: setup.Packet) bool {
        if (self.state == .default) {
            self.out_of_order += 1;
            return false;
        }
        self.configuration = @truncate(packet.value);
        self.state = if (self.configuration == 0) .address else .configured;
        return true;
    }

    /// Stage a control-read answer, cut to what the host asked for. A host
    /// that asks for less than the descriptor holds gets what it asked for,
    /// which is how the two-pass descriptor read works.
    fn stage(self: *Device, bytes: []const u8, wanted: u16) bool {
        const want: usize = @min(bytes.len, @as(usize, wanted));
        const room: usize = @min(want, self.reply.len);
        @memcpy(self.reply[0..room], bytes[0..room]);
        self.reply_len = @intCast(room);
        self.reply_ready = true;
        return true;
    }

    /// The host drained the control-read answer.
    pub fn takeReply(self: *Device, into: []u8) u16 {
        const len: usize = @min(self.reply_len, into.len);
        @memcpy(into[0..len], self.reply[0..len]);
        self.reply_ready = false;
        return @intCast(len);
    }

    /// A bulk OUT packet lands on the endpoint. Only a configured device has
    /// endpoints at all: dev took the bytes whatever state it was in.
    pub fn bulkOut(self: *Device, bytes: []const u8) bool {
        if (self.state != .configured) {
            self.out_of_order += 1;
            return false;
        }
        if (self.storage) |function| {
            if (function.command(bytes)) return true;
            self.out_of_order += 1;
            return false;
        }
        const len: usize = @min(bytes.len, self.echo.len);
        @memcpy(self.echo[0..len], bytes[0..len]);
        self.echo_len = @intCast(len);
        self.echo_ready = true;
        return true;
    }

    /// The bulk IN side answers only what the endpoint was given.
    pub fn takeEcho(self: *Device, into: []u8) u16 {
        const len: usize = @min(self.echo_len, into.len);
        @memcpy(into[0..len], self.echo[0..len]);
        self.echo_ready = false;
        self.echo_len = 0;
        return @intCast(len);
    }

    pub fn hasDisk(self: *const Device) bool {
        return self.storage != null;
    }

    /// Whether the bulk IN endpoint has a packet owed: the storage
    /// function's data or CSW, or the echo.
    pub fn bulkPending(self: *const Device) bool {
        if (self.storage) |function| return function.pending();
        return self.echo_ready;
    }

    /// The next bulk IN packet, from whichever function owns the endpoint.
    pub fn takeIn(self: *Device, into: []u8) u16 {
        if (self.storage) |function| return @intCast(function.reply(into));
        return self.takeEcho(into);
    }

    pub fn refusals(self: *const Device) u32 {
        return self.unsupported + self.out_of_order;
    }

    pub fn quiet(self: *const Device) bool {
        return self.setups == 0 and self.refusals() == 0;
    }
};
