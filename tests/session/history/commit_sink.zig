const std = @import("std");
const recorder = @import("ra8").session.history_recorder;
const gpa = std.testing.allocator;

pub const Sink = struct {
    bytes: std.ArrayList(u8) = .empty,
    appends: usize = 0,
    flushes: usize = 0,
    fail_append: bool = false,
    fail_flush: bool = false,
    fail_truncate: bool = false,

    fn append(context: *anyopaque, data: []const u8) !void {
        const self: *Sink = @ptrCast(@alignCast(context));
        self.appends += 1;
        if (self.fail_append) {
            self.fail_append = false;
            try self.bytes.appendSlice(gpa, data[0 .. data.len / 2]);
            return error.AppendFailed;
        }
        try self.bytes.appendSlice(gpa, data);
    }

    fn flush(context: *anyopaque) !void {
        const self: *Sink = @ptrCast(@alignCast(context));
        self.flushes += 1;
        if (self.fail_flush) {
            self.fail_flush = false;
            return error.FlushFailed;
        }
    }

    fn truncate(context: *anyopaque, length: u64) !void {
        const self: *Sink = @ptrCast(@alignCast(context));
        if (self.fail_truncate) return error.TruncateFailed;
        self.bytes.shrinkRetainingCapacity(@intCast(length));
    }

    pub fn storage(self: *Sink) recorder.Storage {
        return .{ .context = self, .append = append, .flush = flush, .truncate = truncate };
    }
};
