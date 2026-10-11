//! Saving the shell's console log to a file (RA8EMU-1122): every line the
//! log holds, each stamped with the virtual time it ended at the way
//! console_log.save formats it, then any unfinished line. The file is
//! `console.txt` in the project directory (where ra8_gui was started); a
//! save replaces the earlier file.
const std = @import("std");
const console_log = @import("console_log.zig");

pub const file_name = "console.txt";

/// What the last save did, for the save tab's label.
pub const Outcome = enum {
    none,
    saved,
    failed,

    pub fn label(self: Outcome) []const u8 {
        return switch (self) {
            .none => "SAVE",
            .saved => "SAVED",
            .failed => "FAILED",
        };
    }
};

/// Characters the widest label takes: "FAILED".
pub const label_len: usize = 6;

/// Where a save goes: the project directory and the I/O to write it with.
pub const Target = struct {
    io: std.Io,
    dir: std.Io.Dir,
};

/// Write `log` into `target`, stamped.
pub fn save(target: Target, log: *const console_log.Log) !void {
    const file = try target.dir.createFile(target.io, file_name, .{});
    defer file.close(target.io);
    var staging: [4096]u8 = undefined;
    var writer = file.writer(target.io, &staging);
    try log.save(&writer.interface, true);
    try writer.interface.flush();
}

/// Save, reporting the outcome instead of failing: a failed save is logged
/// and the run goes on.
pub fn attempt(target: Target, log: *const console_log.Log) Outcome {
    save(target, log) catch |err| {
        std.log.warn("console save: {s}", .{@errorName(err)});
        return .failed;
    };
    return .saved;
}
