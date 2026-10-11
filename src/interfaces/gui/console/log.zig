//! One SCI channel's console as the UI keeps it (RA8EMU-206): finished
//! lines with the virtual time each one ended at, bounded scrollback, and
//! the text a save-to-file writes. Bytes arrive as the channel sends them;
//! a newline ends a line, a carriage return is dropped, and a line past
//! `max_line` stops growing rather than wrapping, as sci_line does for the
//! run report. The pane draws `lines()`; nothing here touches the board.
const std = @import("std");

pub const max_line: usize = 512;

pub const Entry = struct {
    /// Virtual nanoseconds at the newline that finished the line.
    at_ns: u64,
    text: []u8,
};

pub const Log = struct {
    allocator: std.mem.Allocator,
    /// The most finished lines kept; the oldest goes first.
    capacity: usize,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    pending: [max_line]u8 = undefined,
    pending_len: usize = 0,
    /// Lines that fell off the top of the scrollback.
    dropped: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) Log {
        return .{ .allocator = allocator, .capacity = @max(capacity, 1) };
    }

    pub fn deinit(self: *Log) void {
        for (self.entries.items) |entry| self.allocator.free(entry.text);
        self.entries.deinit(self.allocator);
    }

    /// Takes one byte the channel sent at virtual time `now_ns`.
    pub fn feed(self: *Log, byte: u8, now_ns: u64) error{OutOfMemory}!void {
        switch (byte) {
            '\n' => try self.finish(now_ns),
            '\r' => {},
            else => if (self.pending_len < max_line) {
                self.pending[self.pending_len] = byte;
                self.pending_len += 1;
            },
        }
    }

    pub fn feedAll(self: *Log, bytes: []const u8, now_ns: u64) error{OutOfMemory}!void {
        for (bytes) |byte| try self.feed(byte, now_ns);
    }

    /// The finished lines, oldest first.
    pub fn lines(self: *const Log) []const Entry {
        return self.entries.items;
    }

    /// The line still being printed, not yet ended.
    pub fn partial(self: *const Log) []const u8 {
        return self.pending[0..self.pending_len];
    }

    /// What a save writes: one line per entry, each stamped with its
    /// virtual time in seconds when `stamped`, then any unfinished line.
    pub fn save(self: *const Log, out: anytype, stamped: bool) !void {
        for (self.entries.items) |entry| {
            if (stamped) try stamp(out, entry.at_ns);
            try out.print("{s}\n", .{entry.text});
        }
        if (self.pending_len != 0) try out.print("{s}\n", .{self.partial()});
    }

    fn finish(self: *Log, now_ns: u64) error{OutOfMemory}!void {
        const text = try self.allocator.dupe(u8, self.partial());
        errdefer self.allocator.free(text);
        if (self.entries.items.len == self.capacity) {
            self.allocator.free(self.entries.orderedRemove(0).text);
            self.dropped += 1;
        }
        try self.entries.append(self.allocator, .{ .at_ns = now_ns, .text = text });
        self.pending_len = 0;
    }
};

/// "[  12.000345678] ", seconds and nanoseconds of virtual time.
pub fn stamp(out: anytype, at_ns: u64) !void {
    try out.print("[{d:>4}.{d:0>9}] ", .{ at_ns / std.time.ns_per_s, at_ns % std.time.ns_per_s });
}
