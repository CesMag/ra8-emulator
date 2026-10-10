//! The usbip operation phase (RA8EMU-75 slice 3): answer OP_REQ_DEVLIST
//! and OP_REQ_IMPORT from the bridge's exports until a host imports one.
//! Transport-free: any Io reader and writer will do, so the listener that
//! owns the socket stays a thin shell around `serve`.
const std = @import("std");
const wire = @import("wire.zig");
const exp = @import("exported.zig");

/// What one answered operation request did.
pub const Served = union(enum) {
    /// The host asked for the device list and got it.
    listed,
    /// The host imported this export; URB traffic follows on the stream.
    imported: *const exp.Export,
    /// The host asked for a busid the bridge does not export.
    refused,
};

/// Read one operation request and write its reply. Returns null when the
/// stream ends cleanly before a request starts.
/// The reply is flushed: the host waits on it.
pub fn answer(reader: *std.Io.Reader, writer: *std.Io.Writer, exports: []const exp.Export) !?Served {
    var header: [wire.op_header_len]u8 = undefined;
    const got = try reader.readSliceShort(&header);
    if (got == 0) return null;
    if (got < header.len) return error.Short;
    const request = try wire.OpHeader.decode(&header);
    switch (request.code) {
        wire.op.req_devlist => {
            try exp.writeDevlist(writer, exports);
            try writer.flush();
            return .listed;
        },
        wire.op.req_import => {
            var body: [wire.busid_len]u8 = undefined;
            try reader.readSliceAll(&body);
            const found = try exp.find(exports, &body);
            try exp.writeImport(writer, found);
            try writer.flush();
            return if (found) |item| .{ .imported = item } else .refused;
        },
        else => return error.BadCommand,
    }
}

/// Answer requests until one imports a device (returned) or the host
/// hangs up (null). usbip lists, then reconnects to import, so a listing
/// alone ends with null.
pub fn serve(reader: *std.Io.Reader, writer: *std.Io.Writer, exports: []const exp.Export) !?*const exp.Export {
    while (try answer(reader, writer, exports)) |served| switch (served) {
        .imported => |item| return item,
        .listed, .refused => {},
    };
    return null;
}
