//! Darwin task ledgers and process task counters; no task_threads allocation.
const std = @import("std");
const Raw = @import("metrics.zig").Raw;
extern "c" var mach_task_self_: u32;
const Timebase = extern struct { numer: u32, denom: u32 };
extern "c" fn mach_timebase_info(*Timebase) c_int;
extern "c" fn task_info(u32, u32, [*]u32, *u32) c_int;
extern "c" fn getpid() c_int;
extern "c" fn proc_pidinfo(c_int, c_int, u64, *anyopaque, c_int) c_int;
extern "c" fn sysctlbyname([*:0]const u8, *anyopaque, *usize, ?*anyopaque, usize) c_int;
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
// TASK_VM_INFO stable rev3 prefix, with the SDK's 4-byte natural count.
const Vm = extern struct {
    virtual_size: u64 = 0,
    regions: i32 = 0,
    page_size: i32 = 0,
    resident: u64 = 0,
    resident_peak: u64 = 0,
    device: u64 = 0,
    device_peak: u64 = 0,
    internal: u64 = 0,
    internal_peak: u64 = 0,
    external: u64 = 0,
    external_peak: u64 = 0,
    reusable: u64 = 0,
    reusable_peak: u64 = 0,
    purgeable_pmap: u64 = 0,
    purgeable_resident: u64 = 0,
    purgeable_virtual: u64 = 0,
    compressed: u64 = 0,
    compressed_peak: u64 = 0,
    compressed_lifetime: u64 = 0,
    footprint: u64 = 0,
    minimum_address: u64 = 0,
    maximum_address: u64 = 0,
    footprint_peak: u64 = 0,
    later_revisions: [106]u64 = @splat(0),
};
pub fn read() !Raw {
    var task: Task = undefined;
    if (proc_pidinfo(getpid(), 4, 0, &task, @sizeOf(Task)) != @sizeOf(Task)) return error.Unavailable;
    // TASK_VM_INFO: stable prefix through ledger_phys_footprint_peak (rev3).
    var vm: Vm = .{};
    var count: u32 = @sizeOf(@TypeOf(vm)) / 4;
    if (task_info(mach_task_self_, 22, @ptrCast(&vm), &count) != 0 or count < 38) return error.Unavailable;
    var cores: u32 = 1;
    var size: usize = @sizeOf(u32);
    _ = sysctlbyname("hw.logicalcpu", &cores, &size, null, 0);
    var timebase: Timebase = undefined;
    if (mach_timebase_info(&timebase) != 0) return error.Unavailable;
    return .{ .cpu_ns = try ticksToNs(task.total_user +| task.total_system, timebase.numer, timebase.denom), .cores = cores, .footprint = vm.footprint, .peak_footprint = if (count >= 44) vm.footprint_peak else vm.footprint, .rss = vm.resident, .vsz = vm.virtual_size, .threads = @intCast(@max(task.threads, 0)) };
}

/// PROC_PIDTASKINFO CPU counters use Mach absolute ticks, including on Apple Silicon.
pub fn ticksToNs(ticks: u64, numer: u32, denom: u32) error{InvalidTimebase}!u64 {
    if (denom == 0) return error.InvalidTimebase;
    const ns = @as(u128, ticks) * numer / denom;
    return @intCast(@min(ns, std.math.maxInt(u64)));
}
