//! The slice of Media Foundation the Windows webcam source speaks
//! (RA8EMU-501): the GUIDs, constants and vtable slots for device
//! enumeration and a synchronous IMFSourceReader, plus the four DLL
//! entry points. Plain data, so every host can test it; the externs exist
//! only when building for Windows.
const std = @import("std");
const builtin = @import("builtin");

pub const Guid = std.os.windows.GUID;
pub const HRESULT = i32;

/// The COM calling convention: stdcall on 32-bit x86, the platform's C
/// convention everywhere else. Spelled out rather than `.winapi` so the
/// wrappers and their fake-object tests also build on non-Windows ARM.
pub const cc: std.builtin.CallingConvention = if (builtin.cpu.arch == .x86) .winapi else .c;

pub fn succeeded(hr: HRESULT) bool {
    return hr >= 0;
}

/// MFStartup's version: MF_SDK_VERSION 2 over MF_API_VERSION 0x70.
pub const version: u32 = 0x0002_0070;
/// MFSTARTUP_LITE: no socket layer, which a capture reader never needs.
pub const startup_lite: u32 = 1;
/// MF_SOURCE_READER_FIRST_VIDEO_STREAM.
pub const first_video_stream: u32 = 0xFFFF_FFFC;
/// MF_SOURCE_READERF_ENDOFSTREAM in ReadSample's flags.
pub const end_of_stream: u32 = 0x2;

pub const devsource_source_type = Guid.parse("{c60ac5fe-252a-478f-a0ef-bc8fa5f7cad3}");
pub const devsource_vidcap = Guid.parse("{8ac3587a-4ae7-42d8-99e0-0a6013eef90f}");
pub const mt_major_type = Guid.parse("{48eba18e-f8c9-4687-bf11-0a74c9f96a8f}");
pub const mt_subtype = Guid.parse("{f7e34c9a-42e8-4714-b74b-cb29d72c35e5}");
pub const mt_frame_size = Guid.parse("{1652c33d-d6b2-4012-b834-72030849a37d}");
/// MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING: lets the reader convert to
/// the subtype asked for when the camera only offers MJPG or NV12.
pub const reader_video_processing = Guid.parse("{fb394f3d-ccf1-42ee-bbb3-f9b845d5681d}");
pub const media_type_video = Guid.parse("{73646976-0000-0010-8000-00aa00389b71}");
pub const format_yuy2 = Guid.parse("{32595559-0000-0010-8000-00aa00389b71}");
pub const format_rgb32 = Guid.parse("{00000016-0000-0010-8000-00aa00389b71}");
pub const iid_media_source = Guid.parse("{279a808d-aec7-40c8-9c6b-a6b492c78a66}");

/// MF_MT_FRAME_SIZE packs width over height in one UINT64.
pub fn packSize(width: u32, height: u32) u64 {
    return (@as(u64, width) << 32) | height;
}

pub fn unpackSize(value: u64) struct { width: u32, height: u32 } {
    return .{ .width = @truncate(value >> 32), .height = @truncate(value) };
}

/// Vtable slots, counted from IUnknown's QueryInterface at 0.
pub const slot = struct {
    pub const release = 2;
    pub const get_uint64 = 8; // IMFAttributes
    pub const set_uint32 = 21;
    pub const set_uint64 = 22;
    pub const set_guid = 24;
    pub const activate_object = 33; // IMFActivate, after 33 attribute slots
    pub const shutdown_object = 34;
    pub const reader_get_current_media_type = 6; // IMFSourceReader
    pub const reader_set_current_media_type = 7;
    pub const reader_read_sample = 9;
    pub const sample_to_contiguous = 41; // IMFSample, after 33 attribute slots
    pub const buffer_lock = 3; // IMFMediaBuffer
    pub const buffer_unlock = 4;
};

/// The DLL entry points; empty off Windows so nothing links there.
pub const api = if (builtin.os.tag == .windows) struct {
    pub extern "mfplat" fn MFStartup(ver: u32, flags: u32) callconv(cc) HRESULT;
    pub extern "mfplat" fn MFShutdown() callconv(cc) HRESULT;
    pub extern "mfplat" fn MFCreateAttributes(out: *?*anyopaque, size: u32) callconv(cc) HRESULT;
    pub extern "mfplat" fn MFCreateMediaType(out: *?*anyopaque) callconv(cc) HRESULT;
    pub extern "mf" fn MFEnumDeviceSources(attributes: *anyopaque, out: *?[*]?*anyopaque, count: *u32) callconv(cc) HRESULT;
    pub extern "mfreadwrite" fn MFCreateSourceReaderFromMediaSource(source: *anyopaque, attributes: ?*anyopaque, out: *?*anyopaque) callconv(cc) HRESULT;
    pub extern "ole32" fn CoTaskMemFree(ptr: ?*anyopaque) callconv(cc) void;
} else struct {};
