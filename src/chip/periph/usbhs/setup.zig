//! The eight-byte SETUP packet the host stages into USBREQ..USBLENG, and what
//! a control transfer is once it has been read.
//!
//! dev kept the four registers in its shadow and copied them into a byte
//! array at launch, so nothing in the model could say what the transfer WAS:
//! direction, length and request all had to be re-derived byte by byte at
//! every use. The packet is a value here, and the questions a control
//! transfer turns on are asked of it.
const regs = @import("regs.zig");

/// The standard chapter-9 request codes this model answers.
pub const request = struct {
    pub const get_status: u8 = 0x00;
    pub const set_address: u8 = 0x05;
    pub const get_descriptor: u8 = 0x06;
    pub const get_configuration: u8 = 0x08;
    pub const set_configuration: u8 = 0x09;
};

/// Descriptor types, the high byte of wValue on a GET_DESCRIPTOR.
pub const descriptor = struct {
    pub const device: u8 = 1;
    pub const configuration: u8 = 2;
};

/// One SETUP packet, as the host programmed it.
pub const Packet = struct {
    request_type: u8 = 0,
    code: u8 = 0,
    value: u16 = 0,
    index: u16 = 0,
    length: u16 = 0,

    /// USBREQ carries bmRequestType in its low byte and bRequest in its high
    /// byte; the other three registers are whole fields.
    pub fn fromRegisters(usbreq: u16, usbval: u16, usbindx: u16, usbleng: u16) Packet {
        return .{
            .request_type = @truncate(usbreq),
            .code = @truncate(usbreq >> 8),
            .value = usbval,
            .index = usbindx,
            .length = usbleng,
        };
    }

    /// The data stage runs device to host.
    pub fn deviceToHost(self: Packet) bool {
        return self.request_type & regs.setup.dir_in != 0;
    }

    /// A control read: the device owes bytes and the host will drain them.
    pub fn controlRead(self: Packet) bool {
        return self.deviceToHost() and self.length != 0;
    }

    /// The type half of GET_DESCRIPTOR's wValue.
    pub fn descriptorType(self: Packet) u8 {
        return @truncate(self.value >> 8);
    }

    /// The address a SET_ADDRESS asks the device to take.
    pub fn requestedAddress(self: Packet) u8 {
        return @truncate(self.value);
    }
};
