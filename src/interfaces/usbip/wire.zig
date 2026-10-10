//! The USB/IP wire format (Linux usbip, protocol version 1.1.1), the first
//! piece of the bridge that lets a real host attach the emulated USB device
//! (RA8EMU-75). Every field on the wire is big-endian.
//!
//! A session opens with one operation: OP_REQ_DEVLIST asks what is exported,
//! OP_REQ_IMPORT names a busid and, once answered, turns the connection into
//! a URB stream. Each URB is a 48-byte basic header: USBIP_CMD_SUBMIT from
//! the host (followed by its OUT data), USBIP_RET_SUBMIT back (followed by
//! its IN data), and the UNLINK pair for a cancelled one.
//!
//! This file only packs and unpacks those records. The listener and the
//! routing onto the emulated device come in later slices.
const std = @import("std");

/// The client side of the same records (RA8EMU-75 slice 5).
pub const client = @import("client.zig");

pub const version: u16 = 0x0111;

/// Operation codes, sent before a device is imported.
pub const op = struct {
    pub const req_devlist: u16 = 0x8005;
    pub const rep_devlist: u16 = 0x0005;
    pub const req_import: u16 = 0x8003;
    pub const rep_import: u16 = 0x0003;
};

/// URB commands, sent after a device is imported.
pub const cmd = struct {
    pub const submit: u32 = 1;
    pub const unlink: u32 = 2;
    pub const ret_submit: u32 = 3;
    pub const ret_unlink: u32 = 4;
};

pub const op_header_len: usize = 8;
pub const busid_len: usize = 32;
pub const path_len: usize = 256;
pub const device_len: usize = 312;
pub const interface_len: usize = 4;
pub const basic_len: usize = 48;

pub const Error = error{ Short, BadVersion, BadCommand, TooLong, BadDirection };

/// The kernel's USB speed numbers, as usbip reports them.
pub const Speed = enum(u32) { unknown = 0, low = 1, full = 2, high = 3, super = 5 };

pub const Direction = enum(u32) { out = 0, in = 1 };

/// The 8-byte header every operation request and reply starts with.
pub const OpHeader = struct {
    code: u16,
    status: u32 = 0,

    pub fn encode(self: OpHeader, out: *[op_header_len]u8) void {
        std.mem.writeInt(u16, out[0..2], version, .big);
        std.mem.writeInt(u16, out[2..4], self.code, .big);
        std.mem.writeInt(u32, out[4..8], self.status, .big);
    }

    pub fn decode(bytes: []const u8) Error!OpHeader {
        if (bytes.len < op_header_len) return error.Short;
        if (std.mem.readInt(u16, bytes[0..2], .big) != version) return error.BadVersion;
        return .{
            .code = std.mem.readInt(u16, bytes[2..4], .big),
            .status = std.mem.readInt(u32, bytes[4..8], .big),
        };
    }
};

/// One exported device, as OP_REP_DEVLIST lists it and OP_REP_IMPORT
/// answers it.
pub const Device = struct {
    path: []const u8,
    busid: []const u8,
    busnum: u32,
    devnum: u32,
    speed: Speed,
    vendor: u16,
    product: u16,
    bcd_device: u16,
    class: u8 = 0,
    subclass: u8 = 0,
    protocol: u8 = 0,
    configuration_value: u8 = 1,
    configurations: u8 = 1,
    interfaces: u8 = 1,

    pub fn encode(self: Device, out: *[device_len]u8) Error!void {
        if (self.path.len >= path_len or self.busid.len >= busid_len) return error.TooLong;
        @memset(out, 0);
        @memcpy(out[0..self.path.len], self.path);
        @memcpy(out[path_len..][0..self.busid.len], self.busid);
        const tail = out[path_len + busid_len ..];
        std.mem.writeInt(u32, tail[0..4], self.busnum, .big);
        std.mem.writeInt(u32, tail[4..8], self.devnum, .big);
        std.mem.writeInt(u32, tail[8..12], @backingInt(self.speed), .big);
        std.mem.writeInt(u16, tail[12..14], self.vendor, .big);
        std.mem.writeInt(u16, tail[14..16], self.product, .big);
        std.mem.writeInt(u16, tail[16..18], self.bcd_device, .big);
        tail[18..24].* = .{ self.class, self.subclass, self.protocol, self.configuration_value, self.configurations, self.interfaces };
    }
};

/// One interface entry, which OP_REP_DEVLIST appends after each device.
pub const Interface = struct {
    class: u8,
    subclass: u8 = 0,
    protocol: u8 = 0,

    pub fn encode(self: Interface, out: *[interface_len]u8) void {
        out.* = .{ self.class, self.subclass, self.protocol, 0 };
    }
};

/// The busid an OP_REQ_IMPORT body asks for, cut at its first NUL.
pub fn importBusid(body: []const u8) Error![]const u8 {
    if (body.len < busid_len) return error.Short;
    const field = body[0..busid_len];
    const end = std.mem.indexOfScalar(u8, field, 0) orelse busid_len;
    return field[0..end];
}

/// USBIP_CMD_SUBMIT: one URB the host wants run on an endpoint.
pub const Submit = struct {
    seqnum: u32,
    devid: u32,
    direction: Direction,
    ep: u32,
    transfer_flags: u32,
    length: u32,
    start_frame: u32,
    packets: u32,
    interval: u32,
    setup: [8]u8,

    pub fn decode(bytes: []const u8) Error!Submit {
        const at = try basic(bytes, cmd.submit);
        return .{
            .seqnum = word(bytes, 4),
            .devid = word(bytes, 8),
            .direction = at,
            .ep = word(bytes, 16),
            .transfer_flags = word(bytes, 20),
            .length = word(bytes, 24),
            .start_frame = word(bytes, 28),
            .packets = word(bytes, 32),
            .interval = word(bytes, 36),
            .setup = bytes[40..48].*,
        };
    }

    /// Bytes of OUT data that follow the header on the wire.
    pub fn outBytes(self: Submit) u32 {
        return if (self.direction == .out) self.length else 0;
    }
};

/// USBIP_CMD_UNLINK: cancel the URB with seqnum `victim`.
pub const Unlink = struct {
    seqnum: u32,
    victim: u32,

    pub fn decode(bytes: []const u8) Error!Unlink {
        _ = try basic(bytes, cmd.unlink);
        return .{ .seqnum = word(bytes, 4), .victim = word(bytes, 20) };
    }
};

/// The command a basic header carries, without checking anything else.
pub fn command(bytes: []const u8) Error!u32 {
    if (bytes.len < basic_len) return error.Short;
    return word(bytes, 0);
}

/// USBIP_RET_SUBMIT for `seqnum`; IN data of `actual` bytes follows it.
/// The protocol sends devid, direction and ep as zero in a reply.
pub fn retSubmit(out: *[basic_len]u8, seqnum: u32, status: i32, actual: u32) void {
    reply(out, cmd.ret_submit, seqnum, status);
    std.mem.writeInt(u32, out[24..28], actual, .big);
}

/// USBIP_RET_UNLINK for `seqnum`: status 0 means the URB had already
/// completed, -ECONNRESET that the unlink caught it.
pub fn retUnlink(out: *[basic_len]u8, seqnum: u32, status: i32) void {
    reply(out, cmd.ret_unlink, seqnum, status);
}

fn reply(out: *[basic_len]u8, code: u32, seqnum: u32, status: i32) void {
    @memset(out, 0);
    std.mem.writeInt(u32, out[0..4], code, .big);
    std.mem.writeInt(u32, out[4..8], seqnum, .big);
    std.mem.writeInt(i32, out[20..24], status, .big);
}

fn basic(bytes: []const u8, want: u32) Error!Direction {
    if (try command(bytes) != want) return error.BadCommand;
    return switch (word(bytes, 12)) {
        0 => .out,
        1 => .in,
        else => error.BadDirection,
    };
}

fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .big);
}
