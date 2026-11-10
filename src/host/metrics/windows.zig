//! Win32 process counters and Toolhelp thread inventory, without heap buffers.
const std = @import("std");
const w = std.os.windows;
const Raw = @import("metrics.zig").Raw;
// PROCESS_MEMORY_COUNTERS layout, including unused fields required by its ABI.
const Memory = extern struct {
    cb: u32 = @sizeOf(Memory),
    faults: u32 = 0,
    peak_working: usize = 0,
    working: usize = 0,
    peak_paged: usize = 0,
    paged: usize = 0,
    peak_nonpaged: usize = 0,
    nonpaged: usize = 0,
    pagefile: usize = 0,
    peak_pagefile: usize = 0,
};
const Thread = extern struct {
    size: u32 = @sizeOf(Thread),
    usage: u32 = 0,
    id: u32 = 0,
    owner: u32 = 0,
    priority: i32 = 0,
    delta: i32 = 0,
    flags: u32 = 0,
};
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) w.HANDLE;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn GetProcessTimes(w.HANDLE, *u64, *u64, *u64, *u64) callconv(.winapi) w.BOOL;
extern "kernel32" fn K32GetProcessMemoryInfo(w.HANDLE, *Memory, u32) callconv(.winapi) w.BOOL;
extern "kernel32" fn CreateToolhelp32Snapshot(u32, u32) callconv(.winapi) w.HANDLE;
extern "kernel32" fn Thread32First(w.HANDLE, *Thread) callconv(.winapi) w.BOOL;
extern "kernel32" fn Thread32Next(w.HANDLE, *Thread) callconv(.winapi) w.BOOL;
pub fn read() !Raw {
    const process = GetCurrentProcess();
    var memory: Memory = .{};
    if (!K32GetProcessMemoryInfo(process, &memory, @sizeOf(Memory)).toBool()) return error.Unavailable;
    var created: u64 = 0;
    var exited: u64 = 0;
    var kernel: u64 = 0;
    var user: u64 = 0;
    if (!GetProcessTimes(process, &created, &exited, &kernel, &user).toBool()) return error.Unavailable;
    const snapshot = CreateToolhelp32Snapshot(4, 0);
    if (snapshot == w.INVALID_HANDLE_VALUE) return error.Unavailable;
    defer w.CloseHandle(snapshot);
    var entry: Thread = .{};
    var threads: u32 = 0;
    const pid = GetCurrentProcessId();
    var more = Thread32First(snapshot, &entry).toBool();
    while (more) : (more = Thread32Next(snapshot, &entry).toBool()) {
        if (entry.owner == pid) threads += 1;
    }
    return .{ .cpu_ns = (kernel +| user) *| 100, .rss = memory.working, .threads = threads };
}
