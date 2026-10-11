//! Opens a Windows webcam through Media Foundation (RA8EMU-501): start MF,
//! list the video capture devices, activate `webcam:N`, wrap it in a
//! synchronous source reader with video processing on, and agree YUY2 (or
//! RGB32 when the camera will not give YUY2) at the size asked for, read
//! back from what the reader settled on. The DLL calls sit behind `Calls`
//! so the whole sequence runs against fakes on any host.
const builtin = @import("builtin");
const abi = @import("abi.zig");
const com = @import("com.zig");

pub const Subtype = enum { yuy2, rgb32 };

pub const Error = error{ StartupFailed, NoDevice, ActivateFailed, ReaderFailed, NoFormat };

/// Media Foundation's DLL entry points the opener needs.
pub const Calls = struct {
    startup: *const fn () abi.HRESULT,
    shutdown: *const fn () void,
    create_attributes: *const fn (*?*anyopaque) abi.HRESULT,
    create_media_type: *const fn (*?*anyopaque) abi.HRESULT,
    enum_devices: *const fn (*anyopaque, *?[*]?*anyopaque, *u32) abi.HRESULT,
    create_reader: *const fn (*anyopaque, ?*anyopaque, *?*anyopaque) abi.HRESULT,
    free: *const fn (?*anyopaque) void,
};

/// An open camera: the reader, the device that feeds it, and the format.
pub const Reader = struct {
    calls: Calls,
    reader: *anyopaque,
    activator: *anyopaque,
    subtype: Subtype,
    width: u32,
    height: u32,

    /// Releases the reader, shuts the device down and stops MF.
    pub fn close(self: *Reader) void {
        com.release(self.reader);
        _ = com.shutdown(self.activator);
        com.release(self.activator);
        self.calls.shutdown();
    }
};

pub fn open(calls: Calls, index: u32, width: u32, height: u32) Error!Reader {
    if (!abi.succeeded(calls.startup())) return error.StartupFailed;
    errdefer calls.shutdown();
    const activator = try device(calls, index);
    errdefer {
        _ = com.shutdown(activator);
        com.release(activator);
    }
    var source: ?*anyopaque = null;
    if (!abi.succeeded(com.activate(activator, &abi.iid_media_source, &source)) or source == null) return error.ActivateFailed;
    const reader = makeReader(calls, source.?);
    com.release(source.?);
    const opened = try reader;
    errdefer com.release(opened);
    var result = Reader{ .calls = calls, .reader = opened, .activator = activator, .subtype = .yuy2, .width = width, .height = height };
    try agree(calls, &result);
    return result;
}

/// The `index`th video capture device's activator; the rest are released.
fn device(calls: Calls, index: u32) Error!*anyopaque {
    var attributes: ?*anyopaque = null;
    if (!abi.succeeded(calls.create_attributes(&attributes)) or attributes == null) return error.NoDevice;
    defer com.release(attributes.?);
    if (!abi.succeeded(com.setGuid(attributes.?, &abi.devsource_source_type, &abi.devsource_vidcap))) return error.NoDevice;
    var list: ?[*]?*anyopaque = null;
    var count: u32 = 0;
    if (!abi.succeeded(calls.enum_devices(attributes.?, &list, &count)) or list == null) return error.NoDevice;
    defer calls.free(@ptrCast(list));
    var picked: ?*anyopaque = null;
    for (list.?[0..count], 0..) |entry, i| {
        const each = entry orelse continue;
        if (i == index) picked = each else com.release(each);
    }
    return picked orelse error.NoDevice;
}

fn makeReader(calls: Calls, source: *anyopaque) Error!*anyopaque {
    var attributes: ?*anyopaque = null;
    if (!abi.succeeded(calls.create_attributes(&attributes)) or attributes == null) return error.ReaderFailed;
    defer com.release(attributes.?);
    _ = com.setUint32(attributes.?, &abi.reader_video_processing, 1);
    var reader: ?*anyopaque = null;
    if (!abi.succeeded(calls.create_reader(source, attributes.?, &reader)) or reader == null) return error.ReaderFailed;
    return reader.?;
}

/// Asks for YUY2, then RGB32, and reads back the size the reader settled on.
fn agree(calls: Calls, result: *Reader) Error!void {
    for ([_]Subtype{ .yuy2, .rgb32 }) |subtype| {
        if (!ask(calls, result.*, subtype)) continue;
        result.subtype = subtype;
        var current: ?*anyopaque = null;
        if (!abi.succeeded(com.getCurrentMediaType(result.reader, abi.first_video_stream, &current)) or current == null) return;
        defer com.release(current.?);
        var packed_size: u64 = 0;
        if (!abi.succeeded(com.getUint64(current.?, &abi.mt_frame_size, &packed_size))) return;
        const size = abi.unpackSize(packed_size);
        result.width = size.width;
        result.height = size.height;
        return;
    }
    return error.NoFormat;
}

fn ask(calls: Calls, result: Reader, subtype: Subtype) bool {
    var media_type: ?*anyopaque = null;
    if (!abi.succeeded(calls.create_media_type(&media_type)) or media_type == null) return false;
    defer com.release(media_type.?);
    const guid = switch (subtype) {
        .yuy2 => &abi.format_yuy2,
        .rgb32 => &abi.format_rgb32,
    };
    _ = com.setGuid(media_type.?, &abi.mt_major_type, &abi.media_type_video);
    _ = com.setGuid(media_type.?, &abi.mt_subtype, guid);
    _ = com.setUint64(media_type.?, &abi.mt_frame_size, abi.packSize(result.width, result.height));
    return abi.succeeded(com.setCurrentMediaType(result.reader, abi.first_video_stream, media_type.?));
}

/// The real DLL calls on Windows; null elsewhere.
pub fn system() ?Calls {
    if (builtin.os.tag != .windows) return null;
    return Live.calls;
}

const Live = if (builtin.os.tag == .windows) struct {
    const api = abi.api;
    const calls = Calls{ .startup = startup, .shutdown = shutdown, .create_attributes = attributes, .create_media_type = mediaType, .enum_devices = devices, .create_reader = reader, .free = free };
    fn startup() abi.HRESULT {
        return api.MFStartup(abi.version, abi.startup_lite);
    }
    fn shutdown() void {
        _ = api.MFShutdown();
    }
    fn attributes(out: *?*anyopaque) abi.HRESULT {
        return api.MFCreateAttributes(out, 1);
    }
    fn mediaType(out: *?*anyopaque) abi.HRESULT {
        return api.MFCreateMediaType(out);
    }
    fn devices(attributes_in: *anyopaque, out: *?[*]?*anyopaque, count: *u32) abi.HRESULT {
        return api.MFEnumDeviceSources(attributes_in, out, count);
    }
    fn reader(source: *anyopaque, attributes_in: ?*anyopaque, out: *?*anyopaque) abi.HRESULT {
        return api.MFCreateSourceReaderFromMediaSource(source, attributes_in, out);
    }
    fn free(ptr: ?*anyopaque) void {
        api.CoTaskMemFree(ptr);
    }
} else struct {};
