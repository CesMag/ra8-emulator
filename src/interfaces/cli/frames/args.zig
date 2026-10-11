//! CLI arguments for still and sequential panel captures.
const std = @import("std");
const world_flags = @import("../world_flags.zig");

pub const Options = struct {
    frames_out: ?[]const u8 = null,
    eink_log: ?[]const u8 = null,
    frames_every: usize = 1,
    gif_out: ?[]const u8 = null,
    frame_on_settle: ?[]const u8 = null,
    video_out: ?[]const u8 = null,
    settle_window_ns: u64 = 50_000_000,
};

pub fn parse(options: *Options, argv: []const []const u8, index: *usize) !bool {
    const flag = argv[index.*];
    if (std.mem.eql(u8, flag, "--eink-log")) {
        options.eink_log = try world_flags.next(argv, index);
    } else if (std.mem.eql(u8, flag, "--frames-out")) {
        options.frames_out = try world_flags.next(argv, index);
    } else if (std.mem.eql(u8, flag, "--gif-out")) {
        options.gif_out = try world_flags.next(argv, index);
    } else if (std.mem.eql(u8, flag, "--frame-on-settle")) {
        options.frame_on_settle = try world_flags.next(argv, index);
    } else if (std.mem.eql(u8, flag, "--video-out")) {
        options.video_out = try world_flags.next(argv, index);
    } else if (std.mem.eql(u8, flag, "--settle-window-ms")) {
        const millis = try std.fmt.parseInt(u64, try world_flags.next(argv, index), 10);
        if (millis == 0) return error.BadValue;
        options.settle_window_ns = std.math.mul(u64, millis, 1_000_000) catch return error.BadValue;
    } else if (std.mem.eql(u8, flag, "--frames-every")) {
        options.frames_every = try std.fmt.parseInt(usize, try world_flags.next(argv, index), 10);
        if (options.frames_every == 0) return error.BadValue;
    } else return false;
    return true;
}
