//! The console pane's save control (RA8EMU-206): the shown channel's log
//! written to `console-sciN.txt` in the project directory, each line
//! stamped with the virtual time it ended at, the way console_log.save
//! formats it. A save replaces the channel's earlier file.
const std = @import("std");
const console_log = @import("console_log.zig");
const console_pick = @import("ui/console_pick.zig");
const Rect = @import("ra8_render").draw_list.Rect;

/// Longest name fileName gives: "console-sci10.txt" with room to spare.
pub const name_len: usize = 24;

/// The file a save of `channel` writes, in `buffer`.
pub fn fileName(buffer: *[name_len]u8, channel: usize) []const u8 {
    return std.fmt.bufPrint(buffer, "console-sci{d}.txt", .{channel}) catch unreachable;
}

/// Write `log` for `channel` into `dir`, stamped.
pub fn save(io: std.Io, dir: std.Io.Dir, channel: usize, log: *const console_log.Log) !void {
    var buffer: [name_len]u8 = undefined;
    const file = try dir.createFile(io, fileName(&buffer, channel), .{});
    defer file.close(io);
    var staging: [4096]u8 = undefined;
    var writer = file.writer(io, &staging);
    try log.save(&writer.interface, true);
    try writer.interface.flush();
}

/// A click at (`x`, `y`) on the console pane in `area`: true when it fell
/// on the SAVE tab, which saves `logs[channel]` into `dir` when there is
/// one. A failed save is logged and the run goes on.
pub fn click(area: Rect, x: i32, y: i32, io: std.Io, dir: ?std.Io.Dir, logs: []const console_log.Log, channel: usize) bool {
    if (!console_pick.saveTab(area).contains(x, y)) return false;
    const into = dir orelse return true;
    if (channel >= logs.len) return true;
    save(io, into, channel, &logs[channel]) catch |err| std.log.warn("console save: {s}", .{@errorName(err)});
    return true;
}
