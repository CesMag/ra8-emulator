//! `--save-state PATH` and `--load-state PATH` on a `--cpu zig` run
//! (RA8EMU-696): the whole run written once its budget is spent, and read
//! back right after reset, before the first instruction. `--snapshot-at
//! TIME:PATH` writes the same file part way, at the first boundary at or past
//! virtual time TIME, and the run keeps going; `--restore PATH` starts from
//! one through `--load-state`'s path (RA8EMU-769). The parsed options are
//! the session's own type (src/session/state_options.zig).
const std = @import("std");
const world_flags = @import("world_flags.zig");
const state_options = @import("ra8_session").state_options;

pub const At = state_options.At;
pub const Options = state_options.Options;

pub fn parse(options: *Options, argv: []const []const u8, index: *usize) !bool {
    const flag = argv[index.*];
    if (std.mem.eql(u8, flag, "--save-state")) {
        options.save = try world_flags.next(argv, index);
    } else if (std.mem.eql(u8, flag, "--load-state") or std.mem.eql(u8, flag, "--restore")) {
        options.load = try world_flags.next(argv, index);
    } else if (std.mem.eql(u8, flag, "--snapshot-at")) {
        options.at = try parseAt(try world_flags.next(argv, index));
    } else return false;
    return true;
}

/// `TIME:PATH`, split at the first colon.
pub fn parseAt(word: []const u8) !At {
    const colon = std.mem.indexOfScalar(u8, word, ':') orelse return error.BadSnapshotAt;
    const path = word[colon + 1 ..];
    if (path.len == 0) return error.BadSnapshotAt;
    return .{ .ns = try parseTime(word[0..colon]), .path = path };
}

const units = [_]struct { suffix: []const u8, ns: u64 }{
    .{ .suffix = "ns", .ns = 1 },
    .{ .suffix = "us", .ns = 1_000 },
    .{ .suffix = "ms", .ns = 1_000_000 },
    .{ .suffix = "s", .ns = 1_000_000_000 },
};

/// `40us`, `500ms`, `2s`, `100ns`, or a bare number of seconds, in virtual
/// nanoseconds.
pub fn parseTime(word: []const u8) !u64 {
    var digits = word;
    var scale: u64 = 1_000_000_000;
    for (units) |unit| if (std.mem.endsWith(u8, word, unit.suffix)) {
        digits = word[0 .. word.len - unit.suffix.len];
        scale = unit.ns;
        break;
    };
    const value = std.fmt.parseInt(u64, digits, 10) catch return error.BadTime;
    return std.math.mul(u64, value, scale) catch error.BadTime;
}
