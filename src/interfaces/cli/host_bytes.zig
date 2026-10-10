//! Host handles as the byte sources the board's models read (ADR 0004):
//! the CLI opens them through the host library and hands each model only
//! the interface it declares.
const std = @import("std");
const host_read = @import("ra8_host").host_read;
const ByteSource = @import("../../chip/periph/byte_source.zig").ByteSource;

/// The byte source that reads `handle` without waiting.
pub fn of(handle: host_read.Handle) ByteSource {
    return .{ .context = host_read.word(handle), .readFn = host_read.readWord };
}

/// The process's own stdin, for `--console`.
pub fn stdin() ByteSource {
    return of(host_read.stdin());
}

/// PATH, a file or a FIFO, opened without blocking, so a FIFO with no
/// writer yet does not hold up the run. `flag` leads the complaint.
pub fn open(io: std.Io, flag: []const u8, path: []const u8) !ByteSource {
    const handle = host_read.open(io, path) catch |err| {
        std.debug.print("{s}{s}: {s}\n", .{ flag, path, @errorName(err) });
        return err;
    };
    return of(handle);
}
