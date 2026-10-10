//! The `--touch X,Y` and `--touch-seq X:Y,X:Y,...` spellings, read into
//! contacts on the panel. `--touch-seq` is the form the firmware tree's
//! hil.conf files pass through HIL_EMU_ARGS (touch_cal's five raw points).
//!
//! Its own file so cli.zig keeps room for flags: what a contact spec looks
//! like is a separate question from which flags exist.
const std = @import("std");
const gt911 = @import("ra8_components").gt911;

/// Whether `flag` is one of the touch flags this file reads.
pub fn claims(flag: []const u8) bool {
    return std.mem.eql(u8, flag, "--touch") or std.mem.eql(u8, flag, "--touch-seq");
}

/// One touch flag's value. For `--touch`, "@PATH" names a live host
/// source and anything else is a contact queued before the run. For
/// `--touch-seq`, every comma-separated "X:Y" is queued in order.
pub fn take(options: anytype, flag: []const u8, spec: []const u8) !void {
    if (std.mem.eql(u8, flag, "--touch-seq")) {
        var points = std.mem.splitScalar(u8, spec, ',');
        while (points.next()) |point| try queue(options, try parseWith(point, ':'));
        return;
    }
    if (spec.len > 1 and spec[0] == '@') {
        options.touch_in = spec[1..];
        return;
    }
    try queue(options, try parse(spec));
}

fn queue(options: anytype, contact: gt911.Contact) !void {
    if (options.touch_count >= options.touches.len) return error.TooManyTouches;
    options.touches[options.touch_count] = contact;
    options.touch_count += 1;
}

/// "X,Y" as a contact on the panel, in the panel's own coordinates.
pub fn parse(spec: []const u8) !gt911.Contact {
    return parseWith(spec, ',');
}

fn parseWith(spec: []const u8, separator: u8) !gt911.Contact {
    const split = std.mem.indexOfScalar(u8, spec, separator) orelse return error.BadTouch;
    return .{
        .x = try std.fmt.parseInt(u16, spec[0..split], 10),
        .y = try std.fmt.parseInt(u16, spec[split + 1 ..], 10),
    };
}
