//! What the USB/IP bridge tells a host about the device it exports
//! (RA8EMU-75): the device record and interface list built from the
//! descriptors the firmware itself serves, and the OP_REP_DEVLIST and
//! OP_REP_IMPORT replies that carry them.
//!
//! The descriptors are the bytes the firmware answered GET_DESCRIPTOR with,
//! so a host sees the same vendor, product and class it would on silicon.
const std = @import("std");
const wire = @import("wire.zig");
/// The operation phase built on these exports.
pub const server = @import("server.zig");
/// The loopback socket that runs `server` for usbip hosts.
pub const listen = @import("listen.zig");
/// The board device the bridge exports.
pub const board = @import("board.zig");
/// `--usbip PORT`: the live bridge on the board's USB tick.
pub const run = @import("run.zig");
/// Bulk URBs on the FS device's pipes.
pub const urb = @import("urb.zig");
/// Endpoint 0 control URBs through the DCP.
pub const control = @import("control.zig");
/// The imported connection's SUBMIT/UNLINK traffic.
pub const session = @import("session.zig");
/// The host taken away: recorded commands fed back with replies muted.
pub const replay = @import("replay.zig");
/// The live bridge a run polls at each board boundary.
pub const bridge = @import("bridge.zig");

/// A composite CDC device has two interfaces; room for a few more.
pub const max_interfaces: usize = 8;

pub const device_descriptor_len: usize = 18;
const type_device: u8 = 1;
const type_config: u8 = 2;
const type_interface: u8 = 4;

pub const Error = error{ BadDescriptor, TooManyInterfaces } || wire.Error;

/// One device as the bridge offers it.
pub const Export = struct {
    device: wire.Device,
    interfaces: [max_interfaces]wire.Interface = undefined,
    count: u8 = 0,

    pub fn list(self: *const Export) []const wire.Interface {
        return self.interfaces[0..self.count];
    }
};

/// Where and how fast the exported device sits on the virtual bus.
pub const Place = struct {
    path: []const u8,
    busid: []const u8,
    busnum: u32 = 1,
    devnum: u32 = 2,
    speed: wire.Speed,
};

/// Builds the export from a device descriptor and a full configuration
/// descriptor (the 9-byte header and everything wTotalLength covers).
pub fn fromDescriptors(place: Place, device: []const u8, config: []const u8) Error!Export {
    if (device.len < device_descriptor_len or device[1] != type_device) return error.BadDescriptor;
    if (config.len < 9 or config[1] != type_config) return error.BadDescriptor;
    var out = Export{ .device = .{
        .path = place.path,
        .busid = place.busid,
        .busnum = place.busnum,
        .devnum = place.devnum,
        .speed = place.speed,
        .vendor = std.mem.readInt(u16, device[8..10], .little),
        .product = std.mem.readInt(u16, device[10..12], .little),
        .bcd_device = std.mem.readInt(u16, device[12..14], .little),
        .class = device[4],
        .subclass = device[5],
        .protocol = device[6],
        .configuration_value = config[5],
        .configurations = device[17],
        .interfaces = config[4],
    } };
    try collect(&out, config);
    return out;
}

/// Adds each interface's alternate setting 0, in descriptor order.
fn collect(out: *Export, config: []const u8) Error!void {
    var at: usize = 0;
    while (at + 2 <= config.len) {
        const len = config[at];
        if (len < 2 or at + len > config.len) return error.BadDescriptor;
        const entry = config[at .. at + len];
        if (entry[1] == type_interface and len >= 9 and entry[3] == 0) {
            if (out.count == max_interfaces) return error.TooManyInterfaces;
            out.interfaces[out.count] = .{ .class = entry[5], .subclass = entry[6], .protocol = entry[7] };
            out.count += 1;
        }
        at += len;
    }
}

/// OP_REP_DEVLIST: the header, the device count, then each device record
/// followed by its interface entries.
pub fn writeDevlist(writer: anytype, exports: []const Export) !void {
    var header: [wire.op_header_len]u8 = undefined;
    (wire.OpHeader{ .code = wire.op.rep_devlist }).encode(&header);
    try writer.writeAll(&header);
    try writer.writeInt(u32, @intCast(exports.len), .big);
    for (exports) |*item| {
        var record: [wire.device_len]u8 = undefined;
        try item.device.encode(&record);
        try writer.writeAll(&record);
        for (item.list()) |entry| {
            var bytes: [wire.interface_len]u8 = undefined;
            entry.encode(&bytes);
            try writer.writeAll(&bytes);
        }
    }
}

/// The export an OP_REQ_IMPORT body asks for, if the bridge has it.
pub fn find(exports: []const Export, body: []const u8) wire.Error!?*const Export {
    const busid = try wire.importBusid(body);
    for (exports) |*item| {
        if (std.mem.eql(u8, item.device.busid, busid)) return item;
    }
    return null;
}

/// OP_REP_IMPORT: status 0 and the device record, or status 1 alone when
/// the busid names nothing exported.
pub fn writeImport(writer: anytype, found: ?*const Export) !void {
    var header: [wire.op_header_len]u8 = undefined;
    (wire.OpHeader{ .code = wire.op.rep_import, .status = if (found == null) 1 else 0 }).encode(&header);
    try writer.writeAll(&header);
    const item = found orelse return;
    var record: [wire.device_len]u8 = undefined;
    try item.device.encode(&record);
    try writer.writeAll(&record);
}
