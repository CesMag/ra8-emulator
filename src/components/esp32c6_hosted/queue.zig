//! A small first-in first-out queue of frames waiting for the host.
//!
//! The C6 can owe the host more than one frame at once: an RPC answer and
//! the event that follows it. DATA_READY stays high while any is queued.
const frame = @import("frame.zig");

/// Frames the model may hold for the host at once.
pub const capacity: usize = 4;

pub const Queue = struct {
    slots: [capacity][frame.frame_size]u8 = undefined,
    head: usize = 0,
    len: usize = 0,

    /// Appends a copy of `item`; false when the queue is full.
    pub fn push(self: *Queue, item: *const [frame.frame_size]u8) bool {
        if (self.len == capacity) return false;
        self.slots[(self.head + self.len) % capacity] = item.*;
        self.len += 1;
        return true;
    }

    /// Moves the oldest frame into `out`; false when the queue is empty.
    pub fn pop(self: *Queue, out: *[frame.frame_size]u8) bool {
        if (self.len == 0) return false;
        out.* = self.slots[self.head];
        self.head = (self.head + 1) % capacity;
        self.len -= 1;
        return true;
    }

    pub fn isEmpty(self: *const Queue) bool {
        return self.len == 0;
    }
};
