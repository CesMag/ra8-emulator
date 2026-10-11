//! Calls into Media Foundation's COM objects through their vtables
//! (RA8EMU-501), no C headers: a COM pointer's first word is its vtable,
//! and each method takes the object as its first argument. The wrappers
//! cover only what the webcam reader uses; slots come from mf_abi.
const abi = @import("abi.zig");

const Guid = abi.Guid;
const HRESULT = abi.HRESULT;

/// The function in `object`'s vtable at `index`, typed as `F`.
pub fn method(comptime F: type, object: *anyopaque, index: usize) F {
    const vtable: *const [*]const ?*const anyopaque = @ptrCast(@alignCast(object));
    return @ptrCast(@alignCast(vtable.*[index].?));
}

pub fn release(object: *anyopaque) void {
    _ = method(*const fn (*anyopaque) callconv(abi.cc) u32, object, abi.slot.release)(object);
}

pub fn setGuid(attributes: *anyopaque, key: *const Guid, value: *const Guid) HRESULT {
    const F = *const fn (*anyopaque, *const Guid, *const Guid) callconv(abi.cc) HRESULT;
    return method(F, attributes, abi.slot.set_guid)(attributes, key, value);
}

pub fn setUint32(attributes: *anyopaque, key: *const Guid, value: u32) HRESULT {
    const F = *const fn (*anyopaque, *const Guid, u32) callconv(abi.cc) HRESULT;
    return method(F, attributes, abi.slot.set_uint32)(attributes, key, value);
}

pub fn setUint64(attributes: *anyopaque, key: *const Guid, value: u64) HRESULT {
    const F = *const fn (*anyopaque, *const Guid, u64) callconv(abi.cc) HRESULT;
    return method(F, attributes, abi.slot.set_uint64)(attributes, key, value);
}

pub fn getUint64(attributes: *anyopaque, key: *const Guid, value: *u64) HRESULT {
    const F = *const fn (*anyopaque, *const Guid, *u64) callconv(abi.cc) HRESULT;
    return method(F, attributes, abi.slot.get_uint64)(attributes, key, value);
}

/// IMFActivate::ActivateObject: the media source behind a device.
pub fn activate(activator: *anyopaque, iid: *const Guid, out: *?*anyopaque) HRESULT {
    const F = *const fn (*anyopaque, *const Guid, *?*anyopaque) callconv(abi.cc) HRESULT;
    return method(F, activator, abi.slot.activate_object)(activator, iid, out);
}

pub fn shutdown(activator: *anyopaque) HRESULT {
    const F = *const fn (*anyopaque) callconv(abi.cc) HRESULT;
    return method(F, activator, abi.slot.shutdown_object)(activator);
}

pub fn setCurrentMediaType(reader: *anyopaque, stream: u32, media_type: *anyopaque) HRESULT {
    const F = *const fn (*anyopaque, u32, ?*u32, *anyopaque) callconv(abi.cc) HRESULT;
    return method(F, reader, abi.slot.reader_set_current_media_type)(reader, stream, null, media_type);
}

pub fn getCurrentMediaType(reader: *anyopaque, stream: u32, out: *?*anyopaque) HRESULT {
    const F = *const fn (*anyopaque, u32, *?*anyopaque) callconv(abi.cc) HRESULT;
    return method(F, reader, abi.slot.reader_get_current_media_type)(reader, stream, out);
}

/// One synchronous IMFSourceReader::ReadSample; `sample` stays null on a
/// gap or at the end of the stream.
pub fn readSample(reader: *anyopaque, stream: u32, flags: *u32, sample: *?*anyopaque) HRESULT {
    const F = *const fn (*anyopaque, u32, u32, ?*u32, *u32, ?*i64, *?*anyopaque) callconv(abi.cc) HRESULT;
    var timestamp: i64 = 0;
    return method(F, reader, abi.slot.reader_read_sample)(reader, stream, 0, null, flags, &timestamp, sample);
}

pub fn toContiguous(sample: *anyopaque, buffer: *?*anyopaque) HRESULT {
    const F = *const fn (*anyopaque, *?*anyopaque) callconv(abi.cc) HRESULT;
    return method(F, sample, abi.slot.sample_to_contiguous)(sample, buffer);
}

/// IMFMediaBuffer::Lock: the bytes stay valid until unlock.
pub fn lock(buffer: *anyopaque, bytes: *?[*]u8, length: *u32) HRESULT {
    const F = *const fn (*anyopaque, *?[*]u8, ?*u32, *u32) callconv(abi.cc) HRESULT;
    return method(F, buffer, abi.slot.buffer_lock)(buffer, bytes, null, length);
}

pub fn unlock(buffer: *anyopaque) HRESULT {
    const F = *const fn (*anyopaque) callconv(abi.cc) HRESULT;
    return method(F, buffer, abi.slot.buffer_unlock)(buffer);
}
