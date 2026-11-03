//! An event log segment's bytes, their scan and recovery, and the group
//! commit that decides when staged bytes leave the writer's hands.
//!
//! Commit is the caller's clock, never the host's: group commit flushes
//! at the first of 250 ms or 1 MiB since the last commit, on the
//! monotonic time the caller passes in, and nothing in Session sleeps or
//! reads a host clock. A scan walks the frames and answers where the
//! whole ones end: a torn final tail recovers to the last whole frame's
//! boundary, while a whole frame that lies about its length or fails its
//! CRC is a hard error, wherever it sits. A position a round could not
//! have had is the record layer's refusal; this file moves frames, not
//! their meanings.

const std = @import("std");
const format = @import("format.zig");

pub const Clock = struct {
    context: *anyopaque,
    nowFn: *const fn (*anyopaque) u64,
};

pub const CommitPolicy = struct {
    /// Flush when this much time has passed since the last commit, on
    /// the caller's monotonic clock.
    max_delay_ns: u64 = 250 * std.time.ns_per_ms,
    /// ... or when this many staged bytes have piled up.
    max_bytes: usize = 1024 * 1024,
};

pub const Log = struct {
    /// The sink the segment's bytes reach. Its own buffer holds staged
    /// bytes; a commit flushes them out.
    writer: *std.Io.Writer,
    policy: CommitPolicy = .{},
    /// Bytes appended since the last commit.
    pending_bytes: usize = 0,
    last_commit_ns: u64 = 0,
    /// Whether the caller has handed over a first time sample yet; before
    /// that, only the byte threshold can commit.
    have_time: bool = false,

    pub const Decision = enum { no, time, bytes };

    /// What a commit right now would be answering for.
    pub fn shouldCommit(self: *const Log, now_ns: u64) Decision {
        if (self.pending_bytes >= self.policy.max_bytes) return .bytes;
        if (self.have_time and now_ns >= self.last_commit_ns and now_ns - self.last_commit_ns >= self.policy.max_delay_ns) return .time;
        return .no;
    }

    /// Stages one frame at the writer; a commit releases it.
    pub fn append(self: *Log, frame_bytes: []const u8) std.Io.Writer.Error!void {
        try self.writer.writeAll(frame_bytes);
        self.pending_bytes += frame_bytes.len;
    }

    /// Flushes everything staged so far and restarts both thresholds on
    /// the caller's clock.
    pub fn commit(self: *Log, now_ns: u64) std.Io.Writer.Error!void {
        try self.writer.flush();
        self.acknowledge(now_ns);
    }

    /// Called only after the complete batch is durable.
    pub fn acknowledge(self: *Log, now_ns: u64) void {
        self.pending_bytes = 0;
        self.observe(now_ns);
    }

    /// Commits at the first of the two thresholds, on the caller's clock.
    pub fn maybeCommit(self: *Log, now_ns: u64) std.Io.Writer.Error!void {
        if (self.shouldCommit(now_ns) == .no) return;
        try self.commit(now_ns);
    }

    /// Hands the log its first time sample without committing.
    pub fn observe(self: *Log, now_ns: u64) void {
        self.last_commit_ns = if (self.have_time) @max(self.last_commit_ns, now_ns) else now_ns;
        self.have_time = true;
    }
};

/// One frame's place in a segment.
pub const Boundary = struct {
    /// Where the frame starts in the segment's bytes.
    offset: usize,
    /// How many bytes the frame occupies.
    consumed: usize,
    /// The frame's kind, mandatory bit included.
    kind: u16,
};

pub const Recovery = struct {
    /// Where the whole frames end. A torn tail starts here, and recovery
    /// truncates the segment here; without one this is the segment's end.
    complete_end: usize,
    frames: usize,
    torn: bool,
};

/// Walks the segment's frames in order, handing each to `visit`, and
/// stops at the first torn tail. A whole frame that fails is a hard
/// error; a torn tail is the only recoverable stop.
pub fn scan(bytes: []const u8, context: anytype, comptime visit: fn (@TypeOf(context), Boundary) void) format.Error!Recovery {
    var cursor: usize = 0;
    var frames: usize = 0;
    while (cursor < bytes.len) {
        const hit = format.decode(bytes[cursor..]) catch |err| switch (err) {
            error.Truncated => return .{ .complete_end = cursor, .frames = frames, .torn = true },
            else => return err,
        };
        visit(context, .{ .offset = cursor, .consumed = hit.consumed, .kind = hit.frame.kind });
        frames += 1;
        cursor += hit.consumed;
    }
    return .{ .complete_end = bytes.len, .frames = frames, .torn = false };
}
