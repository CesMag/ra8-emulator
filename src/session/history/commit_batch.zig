//! Retryable append and durable flush of one complete staged batch.
const Storage = @import("recorder.zig").Storage;

pub const Batch = struct {
    rollback_needed: bool = false,

    fn rollback(self: *Batch, storage: Storage, committed: u64) !void {
        try storage.truncate(storage.context, committed);
        self.rollback_needed = false;
    }

    pub fn write(self: *Batch, storage: Storage, committed: u64, bytes: []const u8) !void {
        if (self.rollback_needed) try self.rollback(storage, committed);
        self.rollback_needed = true;
        storage.append(storage.context, bytes) catch |err| {
            self.rollback(storage, committed) catch {};
            return err;
        };
        storage.flush(storage.context) catch |err| {
            self.rollback(storage, committed) catch {};
            return err;
        };
        self.rollback_needed = false;
    }
};
