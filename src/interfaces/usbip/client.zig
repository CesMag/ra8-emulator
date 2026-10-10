//! The host side of the USB/IP wire (RA8EMU-75 slice 5): the requests a
//! usbip client sends and the replies it reads back, so a test can attach
//! the emulated device the way `usbip attach` does. wire.zig packs the
//! server side; the layouts are the same and every field is big-endian.
const std = @import("std");
const wire = @import("wire.zig");

/// The list, import and URB steps built on these records (slice 5b).
pub const attach = @import("attach.zig");

pub const import_len = wire.op_header_len + wire.busid_len;

/// OP_REQ_DEVLIST: the operation header alone.
pub fn devlist(out: *[wire.op_header_len]u8) void {
    (wire.OpHeader{ .code = wire.op.req_devlist }).encode(out);
}

/// OP_REQ_IMPORT for `busid`, NUL-padded to its 32-byte field.
pub fn importRequest(out: *[import_len]u8, busid: []const u8) wire.Error!void {
    if (busid.len >= wire.busid_len) return error.TooLong;
    (wire.OpHeader{ .code = wire.op.req_import }).encode(out[0..wire.op_header_len]);
    @memset(out[wire.op_header_len..], 0);
    @memcpy(out[wire.op_header_len..][0..busid.len], busid);
}

/// The fields of a 312-byte device record a client needs to attach it.
pub const Listed = struct {
    busid: []const u8,
    busnum: u32,
    devnum: u32,
    vendor: u16,
    product: u16,

    pub fn decode(bytes: []const u8) wire.Error!Listed {
        if (bytes.len < wire.device_len) return error.Short;
        const field = bytes[wire.path_len..][0..wire.busid_len];
        const tail = bytes[wire.path_len + wire.busid_len ..];
        return .{
            .busid = field[0 .. std.mem.indexOfScalar(u8, field, 0) orelse wire.busid_len],
            .busnum = word(tail, 0),
            .devnum = word(tail, 4),
            .vendor = std.mem.readInt(u16, tail[12..14], .big),
            .product = std.mem.readInt(u16, tail[14..16], .big),
        };
    }

    /// The devid a CMD_SUBMIT names: busnum in the high half, devnum low.
    pub fn devid(self: Listed) u32 {
        return (self.busnum << 16) | (self.devnum & 0xFFFF);
    }
};

/// One URB to send as USBIP_CMD_SUBMIT.
pub const Urb = struct {
    seqnum: u32,
    devid: u32,
    direction: wire.Direction,
    ep: u32,
    length: u32,
    setup: [8]u8 = @splat(0),
};

pub fn submit(out: *[wire.basic_len]u8, urb: Urb) void {
    @memset(out, 0);
    put(out, 0, wire.cmd.submit);
    put(out, 4, urb.seqnum);
    put(out, 8, urb.devid);
    put(out, 12, @backingInt(urb.direction));
    put(out, 16, urb.ep);
    put(out, 24, urb.length);
    out[40..48].* = urb.setup;
}

/// The standard GET_DESCRIPTOR setup packet for `kind`/`index`.
pub fn getDescriptor(kind: u8, index: u8, length: u16) [8]u8 {
    var setup = [8]u8{ 0x80, 6, index, kind, 0, 0, 0, 0 };
    std.mem.writeInt(u16, setup[6..8], length, .little);
    return setup;
}

/// What USBIP_RET_SUBMIT says about a URB; `actual` IN bytes follow it.
pub const Returned = struct {
    seqnum: u32,
    status: i32,
    actual: u32,

    pub fn decode(bytes: []const u8) wire.Error!Returned {
        if (try wire.command(bytes) != wire.cmd.ret_submit) return error.BadCommand;
        return .{ .seqnum = word(bytes, 4), .status = @bitCast(word(bytes, 20)), .actual = word(bytes, 24) };
    }
};

fn put(out: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, out[at..][0..4], value, .big);
}

fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .big);
}
