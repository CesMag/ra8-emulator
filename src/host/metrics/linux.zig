//! Process CPU, resident memory and thread counters parsed in fixed buffers.
const std = @import("std");
const Raw = @import("metrics.zig").Raw;
extern "c" fn sysconf(c_int) c_long;
pub fn read() !Raw {
    var stat_buf: [4096]u8 = undefined;
    var status_buf: [16384]u8 = undefined;
    const stat = try readFile("/proc/self/stat", &stat_buf);
    const status = try readFile("/proc/self/status", &status_buf);
    const ticks = sysconf(2); // _SC_CLK_TCK
    if (ticks <= 0) return error.Unavailable;
    return parse(stat, status, @intCast(ticks));
}
fn readFile(path: [*:0]const u8, into: []u8) ![]const u8 {
    const fd = std.c.open(path, .{ .CLOEXEC = true }, @as(c_uint, 0));
    if (fd < 0) return error.Unavailable;
    defer _ = std.c.close(fd);
    const n = try std.posix.read(fd, into);
    return into[0..n];
}
pub fn parse(stat: []const u8, status: []const u8, ticks: u64) !Raw {
    if (ticks == 0) return error.Unavailable;
    const end = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return error.InvalidStat;
    var fields = std.mem.tokenizeScalar(u8, stat[end + 1 ..], ' ');
    var raw: Raw = .{};
    var index: usize = 3;
    var cpu: u64 = 0;
    while (fields.next()) |field| : (index += 1) {
        if (index == 14 or index == 15) cpu +|= try std.fmt.parseInt(u64, field, 10);
    }
    if (index <= 15) return error.InvalidStat;
    raw.cpu_ns = cpu *| 1_000_000_000 / ticks;
    var lines = std.mem.splitScalar(u8, status, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t");
        const name = words.next() orelse continue;
        const number = words.next() orelse continue;
        const value = std.fmt.parseInt(u64, number, 10) catch continue;
        if (std.mem.eql(u8, name, "VmRSS:")) raw.rss = value *| 1024;
        if (std.mem.eql(u8, name, "Threads:")) raw.threads = @intCast(value);
    }
    return raw;
}
