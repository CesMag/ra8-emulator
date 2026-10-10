//! Typed keys from an interactive Windows console (RA8EMU-723).
//!
//! A console handle is not a pipe or a file: ReadFile on it waits for a
//! whole line, which would stop the run. So host_read sends a console here.
//! The console's input queue is checked with GetNumberOfConsoleInputEvents
//! and, only when it holds something, drained with ReadConsoleInputW. Key
//! presses become bytes; releases, mouse, focus and resize events are
//! dropped. Enter arrives as '\r' and is handed on as '\n', the byte a POSIX
//! terminal in line mode gives the SCI. Only ASCII is passed on.
const std = @import("std");
const windows = std.os.windows;

/// KEY_EVENT_RECORD, as INPUT_RECORD carries it.
pub const KeyEvent = extern struct {
    key_down: windows.BOOL,
    repeat_count: u16,
    virtual_key: u16,
    virtual_scan: u16,
    char: u16,
    control_keys: windows.DWORD,
};

/// INPUT_RECORD: a 16-byte event union behind a 2-byte type tag.
pub const InputRecord = extern struct {
    event_type: u16,
    event: extern union { key: KeyEvent, raw: [16]u8 },
};

pub const key_event: u16 = 0x0001;

comptime {
    std.debug.assert(@sizeOf(KeyEvent) == 16);
    std.debug.assert(@sizeOf(InputRecord) == 20);
}

extern "kernel32" fn GetConsoleMode(console: windows.HANDLE, mode: *windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetNumberOfConsoleInputEvents(console: windows.HANDLE, count: *windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn ReadConsoleInputW(console: windows.HANDLE, records: [*]InputRecord, length: windows.DWORD, read: *windows.DWORD) callconv(.winapi) windows.BOOL;

/// True when `handle` is an interactive console rather than a pipe or file.
pub fn isConsole(handle: windows.HANDLE) bool {
    var mode: windows.DWORD = 0;
    return GetConsoleMode(handle, &mode).toBool();
}

/// Append the bytes one record types to `out` from `at`, and return the new
/// end. A key held down repeats; what does not fit is dropped.
pub fn keyBytes(record: InputRecord, out: []u8, at: usize) usize {
    if (record.event_type != key_event) return at;
    const key = record.event.key;
    if (!key.key_down.toBool() or key.char == 0 or key.char > 0x7F) return at;
    const byte: u8 = if (key.char == '\r') '\n' else @intCast(key.char);
    var end = at;
    var left = @max(key.repeat_count, 1);
    while (left > 0 and end < out.len) : (left -= 1) {
        out[end] = byte;
        end += 1;
    }
    return end;
}

/// Read the keys waiting on console `handle` into `into`. Null means none
/// are waiting, so the run goes on; a console never reads as the end.
pub fn read(handle: windows.HANDLE, into: []u8) ?usize {
    var waiting: windows.DWORD = 0;
    if (!GetNumberOfConsoleInputEvents(handle, &waiting).toBool() or waiting == 0) return null;
    var records: [32]InputRecord = undefined;
    const want: windows.DWORD = @intCast(@min(waiting, records.len, into.len));
    var got: windows.DWORD = 0;
    if (!ReadConsoleInputW(handle, &records, want, &got).toBool()) return null;
    var end: usize = 0;
    for (records[0..got]) |record| end = keyBytes(record, into, end);
    return if (end == 0) null else end;
}
