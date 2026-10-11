//! The Windows side of `--camera-source pipe:` (RA8EMU-585).
//!
//! The emulator is the pipe server: it creates `\\.\pipe\NAME` in
//! PIPE_NOWAIT byte mode, so a writer such as ffmpeg opens it as a plain
//! output file, and a read with nothing waiting returns at once instead of
//! holding the run. A bare NAME means `\\.\pipe\NAME`. Standard input ("-")
//! is checked with PeekNamedPipe first, so an idle anonymous pipe never
//! blocks either. A read that ends in Closed returns 0, which pipe_input
//! treats as the writer hanging up.
const std = @import("std");
const windows = std.os.windows;
const kernel32 = windows.kernel32;

pub const prefix = "\\\\.\\pipe\\";

/// What a failed non-blocking read means for the capture.
pub const Outcome = enum { would_block, listening, closed, failed };

/// Sort a Win32 error from ReadFile or PeekNamedPipe.
pub fn outcome(code: windows.Win32Error) Outcome {
    return switch (code) {
        .NO_DATA => .would_block,
        .PIPE_LISTENING => .listening,
        .BROKEN_PIPE, .PIPE_NOT_CONNECTED => .closed,
        else => .failed,
    };
}

/// The full pipe path for `path`: a bare name gains the `\\.\pipe\` prefix;
/// anything else must already carry it.
pub fn fullName(buf: []u8, path: []const u8) error{ NotAPipe, NameTooLong }![]const u8 {
    if (std.ascii.startsWithIgnoreCase(path, prefix)) {
        if (path.len == prefix.len) return error.NotAPipe;
        if (path.len > buf.len) return error.NameTooLong;
        @memcpy(buf[0..path.len], path);
        return buf[0..path.len];
    }
    if (path.len == 0 or std.mem.indexOfAny(u8, path, "\\/:") != null) return error.NotAPipe;
    if (prefix.len + path.len > buf.len) return error.NameTooLong;
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..path.len], path);
    return buf[0 .. prefix.len + path.len];
}

const access_inbound: windows.DWORD = 0x0000_0001;
const first_instance: windows.DWORD = 0x0008_0000;
const mode_nowait: windows.DWORD = 0x0000_0001;
const reject_remote: windows.DWORD = 0x0000_0008;

extern "kernel32" fn CreateNamedPipeW(
    name: [*:0]const u16,
    open_mode: windows.DWORD,
    pipe_mode: windows.DWORD,
    max_instances: windows.DWORD,
    out_size: windows.DWORD,
    in_size: windows.DWORD,
    timeout_ms: windows.DWORD,
    security: ?*anyopaque,
) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn ReadFile(
    file: windows.HANDLE,
    into: [*]u8,
    len: windows.DWORD,
    read: ?*windows.DWORD,
    overlapped: ?*anyopaque,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn ConnectNamedPipe(pipe: windows.HANDLE, overlapped: ?*anyopaque) callconv(.winapi) windows.BOOL;
extern "kernel32" fn PeekNamedPipe(
    pipe: windows.HANDLE,
    buffer: ?*anyopaque,
    size: windows.DWORD,
    read: ?*windows.DWORD,
    available: ?*windows.DWORD,
    left: ?*windows.DWORD,
) callconv(.winapi) windows.BOOL;

/// Create the pipe server for `path`, sized for one frame of `in_size` bytes.
pub fn serve(path: []const u8, in_size: usize) !windows.HANDLE {
    var name_buf: [256]u8 = undefined;
    const name = try fullName(&name_buf, path);
    var wide: [256:0]u16 = undefined;
    const len = try std.unicode.utf8ToUtf16Le(&wide, name);
    wide[len] = 0;
    const handle = CreateNamedPipeW(
        wide[0..len :0],
        access_inbound | first_instance,
        mode_nowait | reject_remote,
        1,
        0,
        @intCast(@min(in_size, 1 << 20)),
        0,
        null,
    );
    if (handle == windows.INVALID_HANDLE_VALUE) return windows.unexpectedError(windows.GetLastError());
    return handle;
}

/// Read what is waiting on `handle` without blocking. `stdin` marks an
/// inherited handle that may be an anonymous pipe or a file.
pub fn readNow(handle: windows.HANDLE, stdin: bool, into: []u8) error{ WouldBlock, Failed }!usize {
    var want: windows.DWORD = @intCast(@min(into.len, std.math.maxInt(windows.DWORD)));
    if (stdin) {
        var available: windows.DWORD = 0;
        if (PeekNamedPipe(handle, null, 0, null, &available, null).toBool()) {
            if (available == 0) return error.WouldBlock;
            want = @min(want, available);
        } else switch (outcome(windows.GetLastError())) {
            .closed => return 0,
            else => {}, // a file: a plain read never waits
        }
    }
    var got: windows.DWORD = 0;
    if (ReadFile(handle, into.ptr, want, &got, null).toBool()) return got;
    return switch (outcome(windows.GetLastError())) {
        .would_block => error.WouldBlock,
        .listening => {
            _ = ConnectNamedPipe(handle, null);
            return error.WouldBlock;
        },
        .closed => 0,
        .failed => error.Failed,
    };
}
