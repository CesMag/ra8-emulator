//! Carries what the SCI channels send from the engine thread to the
//! window's console logs (RA8EMU-206). The engine side is the channels'
//! tap: each sent byte is stamped with board time and kept in a batch only
//! the engine touches, and at each park the batch moves to an outbox under
//! a short lock. The window drains the outbox into one console_log.Log per
//! channel. Unlike the board snapshot, nothing here may be skipped, so the
//! outbox is a queue, bounded by `limit`: past it, new bytes are counted
//! in `lost` rather than kept, and the window can say so. A tap that was
//! already on the SCI (the session event stream, RA8EMU-192) goes in `next`
//! and still sees every byte, so both read the same sends at the same time.
const std = @import("std");
const console_log = @import("console_log.zig");
const Tap = @import("ra8_chip").periph.sci_tap.Tap;

pub const Byte = struct { channel: u8, byte: u8, at_ns: u64 };

/// Board time, read on the engine thread.
pub const Now = struct {
    ctx: *anyopaque,
    now: *const fn (ctx: *anyopaque) u64,
};

pub const Feed = struct {
    allocator: std.mem.Allocator,
    now: Now,
    /// The most bytes the outbox holds between drains.
    limit: usize = 1 << 16,
    /// Engine side only.
    batch: std.ArrayListUnmanaged(Byte) = .empty,
    batch_lost: u64 = 0,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    /// Under `mutex`.
    outbox: std.ArrayListUnmanaged(Byte) = .empty,
    lost: u64 = 0,
    /// Window side only: the drained outbox, kept for its capacity.
    inbox: std.ArrayListUnmanaged(Byte) = .empty,
    /// Engine side: the tap this one replaced on the SCI, called after.
    next: ?Tap = null,

    pub fn deinit(self: *Feed) void {
        self.batch.deinit(self.allocator);
        self.outbox.deinit(self.allocator);
        self.inbox.deinit(self.allocator);
    }

    /// For the SCI block: records every sent byte with the time it went.
    pub fn tap(self: *Feed) Tap {
        return .{ .ctx = self, .sent = sent };
    }

    fn sent(ctx: *anyopaque, channel: usize, byte: u8) void {
        const self: *Feed = @ptrCast(@alignCast(ctx));
        const entry = Byte{ .channel = @intCast(channel), .byte = byte, .at_ns = self.now.now(self.now.ctx) };
        self.batch.append(self.allocator, entry) catch {
            self.batch_lost += 1;
        };
        if (self.next) |next| next.sent(next.ctx, channel, byte);
    }

    /// Engine side, at a park: hand the batch to the window.
    pub fn publish(self: *Feed) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const room = self.limit -| self.outbox.items.len;
        const kept = @min(room, self.batch.items.len);
        self.outbox.appendSlice(self.allocator, self.batch.items[0..kept]) catch {
            self.lost += self.batch.items.len;
            return self.reset();
        };
        self.lost += self.batch.items.len - kept;
        self.reset();
    }

    fn reset(self: *Feed) void {
        self.lost += self.batch_lost;
        self.batch_lost = 0;
        self.batch.clearRetainingCapacity();
    }

    /// Window side: feed everything handed over since the last drain into
    /// `logs`, one per channel; bytes for a channel past the end are
    /// dropped. Returns the lost count so far.
    pub fn drain(self: *Feed, logs: []console_log.Log) error{OutOfMemory}!u64 {
        self.inbox.clearRetainingCapacity();
        const lost = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            std.mem.swap(std.ArrayListUnmanaged(Byte), &self.inbox, &self.outbox);
            break :blk self.lost;
        };
        for (self.inbox.items) |entry| {
            if (entry.channel < logs.len) try logs[entry.channel].feed(entry.byte, entry.at_ns);
        }
        return lost;
    }
};
