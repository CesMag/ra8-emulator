//! Darwin process CPU, resident memory and thread counters without allocation.
const std = @import("std");
const Raw = @import("metrics.zig").Raw;
const Timebase = extern struct { numer: u32, denom: u32 };
extern "c" fn mach_timebase_info(*Timebase) c_int;
extern "c" fn getpid() c_int;
extern "c" fn proc_pidinfo(c_int, c_int, u64, *anyopaque, c_int) c_int;
// proc_taskinfo's complete ABI layout; unused fields preserve counter offsets.
const Task = extern struct {
    virtual_size: u64,
    resident: u64,
    total_user: u64,
    total_system: u64,
    threads_user: u64,
    threads_system: u64,
    policy: i32,
    faults: i32,
    pageins: i32,
    cow: i32,
    sent: i32,
    received: i32,
    mach_syscalls: i32,
    unix_syscalls: i32,
    switches: i32,
    threads: i32,
    running: i32,
    priority: i32,
};
pub fn read() !Raw {
    var task: Task = undefined;
    if (proc_pidinfo(getpid(), 4, 0, &task, @sizeOf(Task)) != @sizeOf(Task)) return error.Unavailable;
    var timebase: Timebase = undefined;
    if (mach_timebase_info(&timebase) != 0) return error.Unavailable;
    return .{ .cpu_ns = try ticksToNs(task.total_user +| task.total_system, timebase.numer, timebase.denom), .rss = task.resident, .threads = @intCast(@max(task.threads, 0)) };
}

/// PROC_PIDTASKINFO CPU counters use Mach absolute ticks, including on Apple Silicon.
pub fn ticksToNs(ticks: u64, numer: u32, denom: u32) error{InvalidTimebase}!u64 {
    if (denom == 0) return error.InvalidTimebase;
    const ns = @as(u128, ticks) * numer / denom;
    return @intCast(@min(ns, std.math.maxInt(u64)));
}
