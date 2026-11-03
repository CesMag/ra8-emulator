//! Persistent event staging and object-before-log durability.
const std = @import("std");
const commit_batch = @import("commit_batch.zig");
const format = @import("format.zig");
const log_mod = @import("log.zig");
const record = @import("record.zig");
const budget = @import("budget.zig");
const touched_pages = @import("touched_pages.zig");
const manifest_mod = @import("manifest.zig");
const segment_recover = @import("segment_recover.zig");

/// The host storage the recorder writes through, as the application
/// fills it. Session calls these and nothing else about the host.
pub const Storage = struct {
    context: *anyopaque,
    append: *const fn (context: *anyopaque, bytes: []const u8) anyerror!void,
    flush: *const fn (context: *anyopaque) anyerror!void,
    truncate: *const fn (context: *anyopaque, len: u64) anyerror!void,
    /// Makes segment `seg` of `branch` the one appends reach, opened for
    /// appending when it exists and made when it does not, and answers the
    /// bytes it already holds. Null keeps one segment for every line.
    switchSegment: ?*const fn (context: *anyopaque, branch: u32, seg: u32) anyerror!u64 = null,
};

/// Which log segment the recorder appends to.
pub const Segment = struct {
    branch: u32 = 0,
    index: u32 = 0,
};

/// What a recovered segment answered, and the scan a reopen runs.
pub const Recovery = segment_recover.Recovery;
pub const recoverSegment = segment_recover.recoverSegment;

pub const Error = error{ OutOfMemory, WriteFailed, NoObjects } || format.Error;

/// The recorder over one log segment.
/// The object space a checkpoint's saved machine reaches, as the
/// application fills it. `put` stores the bytes under the name the
/// recorder chose; `sync` makes them durable. Object-before-log is the
/// order this module proves: a checkpoint's bytes are durable here
/// before its record can become visible in the log, so a reader never
/// follows a record to an object the storage does not hold.
pub const Objects = struct {
    context: *anyopaque,
    put: *const fn (context: *anyopaque, name: []const u8, bytes: []const u8) anyerror!void,
    sync: *const fn (context: *anyopaque) anyerror!void,
    /// Stores a content-addressed page or blob object (named by its 128-bit
    /// identity) where the application keeps such objects; `sync` makes it
    /// durable like the rest. Null stores them through `put` by hex name.
    putPacked: ?*const fn (context: *anyopaque, id: [16]u8, bytes: []const u8) anyerror!void = null,
};

/// The disk-side budget the application fills: the share this history's
/// bytes must stay under on the volume, and the fresh free-space read the
/// recorder asks for before each commit and checkpoint. Null keeps an
/// unmeasured history, the way an in-RAM session runs. The share and the
/// floor come from the application's budget math; the free-space read
/// crosses as a callback because session never touches the host.
pub const Budget = struct {
    context: *anyopaque,
    /// Bytes the volume has free right now, read fresh per check.
    free: *const fn (context: *anyopaque) anyerror!u64,
    /// This history's share of the volume.
    cap: u64,
    /// The free space the volume must still hold after the bytes go out.
    floor: u64,
    /// The relief the application supplies for a refused commit or
    /// checkpoint: it runs once when the check refuses, before the
    /// refusal stands, so the retry can land. Null keeps a history
    /// that refuses without relief.
    relief: ?*const fn (context: *anyopaque) anyerror!void = null,
};

pub const Recorder = struct {
    gpa: std.mem.Allocator,
    storage: Storage,
    log: log_mod.Log,
    /// The staged bytes between commits; a commit hands them to the
    /// storage as one append and empties it. Heap-owned, so the log's
    /// writer pointer stays valid wherever the recorder itself lives.
    staging: *std.Io.Writer.Allocating,
    /// Bytes the storage holds for this segment so far.
    committed_bytes: u64 = 0,
    /// Total committed bytes across all segments of this history.
    history_bytes: u64 = 0,
    /// Set while re-executing recorded history; skips staging new records
    /// and checkpoint objects.
    replaying: bool = false,
    /// Set once the session stops recording into this history (a different
    /// image loaded with no new history to open): nothing more is staged,
    /// checkpointed or committed.
    stopped: bool = false,
    /// The segment appends reach.
    segment: Segment = .{},
    /// The object space checkpoints write through, as the application
    /// fills it; a recorder without one refuses checkpoints.
    objects: ?Objects = null,
    /// The disk-side budget, as the application fills it; null is
    /// unmeasured, and nothing is refused.
    disk: ?Budget = null,
    /// Bytes the object space holds for this segment's checkpoints, part
    /// of what the budget counts as used.
    object_bytes: u64 = 0,
    root_bytes: u64 = 0,
    /// The pressure the last disk check answered with; the application
    /// reads it to warn at 80 percent before the stop at 100.
    last_pressure: budget.Pressure = .normal,
    /// Optional caller clock, borrowed for the recorder lifetime.
    clock: ?log_mod.Clock = null,
    /// A failed append/flush must be truncated before any retry appends.
    batch: commit_batch.Batch = .{},

    pub fn init(gpa: std.mem.Allocator, storage: Storage, policy: log_mod.CommitPolicy) Error!Recorder {
        const staging = try gpa.create(std.Io.Writer.Allocating);
        errdefer gpa.destroy(staging);
        staging.* = try std.Io.Writer.Allocating.initCapacity(gpa, 4096);
        return .{
            .gpa = gpa,
            .storage = storage,
            .log = .{ .writer = &staging.writer, .policy = policy },
            .staging = staging,
        };
    }

    pub fn deinit(self: *Recorder) void {
        self.staging.deinit();
        self.gpa.destroy(self.staging);
    }

    /// Records an external event at the boundary where it landed.
    pub fn recordBoundary(self: *Recorder, header: record.Header, boundary: record.Boundary) anyerror!void {
        try self.stage(@backingInt(record.Kind.boundary), header, boundary.what, boundary.body);
    }

    /// Records a branch record when a line forks from another.
    pub fn recordBranch(self: *Recorder, header: record.Header, branch: record.Branch) anyerror!void {
        if (self.replaying) return;
        var staging: std.Io.Writer.Allocating = try .initCapacity(self.gpa, 64);
        defer staging.deinit();
        try record.encodeBranch(&staging.writer, header, branch);
        try self.stagePayload(@backingInt(record.Kind.branch), staging.writer.buffered());
    }

    /// Switches the recorder to a new segment for branch `branch`, committing
    /// any pending bytes on the current segment first.
    pub fn switchSegment(self: *Recorder, now_ns: u64, branch: u32, seg: u32) anyerror!void {
        try self.commit(now_ns);
        const sw = self.storage.switchSegment orelse {
            self.segment = .{ .branch = branch, .index = seg };
            return;
        };
        self.committed_bytes = try sw(self.storage.context, branch, seg);
        self.segment = .{ .branch = branch, .index = seg };
    }

    /// Drops every staged byte without committing it.
    pub fn discardStaged(self: *Recorder) void {
        self.staging.writer.end = 0;
        self.log.pending_bytes = 0;
    }

    /// Undoes what a fork that did not complete wrote: the staged bytes go,
    /// the segment is cut back to `cut_at` (its length when the fork opened
    /// it), and appends return to `back`. Best effort: the fork's own
    /// error is the one its caller reports, and bytes left behind name a
    /// branch no graph holds, which every reader skips.
    pub fn abandonSegment(self: *Recorder, back: Segment, cut_at: u64) void {
        self.discardStaged();
        if (self.committed_bytes > cut_at) {
            self.storage.truncate(self.storage.context, cut_at) catch {};
            self.history_bytes -|= self.committed_bytes - cut_at;
            self.committed_bytes = cut_at;
        }
        if (self.segment.branch != back.branch or self.segment.index != back.index)
            self.switchSegment(0, back.branch, back.index) catch {};
    }

    /// Records a host-originated mutation that crossed a dispatching
    /// boundary.
    pub fn recordIntervention(self: *Recorder, header: record.Header, intervention: record.Intervention) anyerror!void {
        try self.stage(@backingInt(record.Kind.intervention), header, intervention.what, intervention.body);
    }

    /// Immutable root objects share the checkpoint budget and durability gate.
    pub fn putRootObject(self: *Recorder, name: []const u8, bytes: []const u8) anyerror!void {
        const objects = self.objects orelse return Error.NoObjects;
        if (self.disk) |watch| _ = try self.checkDisk(watch, self.usedBytes(), bytes.len);
        try objects.put(objects.context, name, bytes);
        try objects.sync(objects.context);
        self.root_bytes += bytes.len;
    }

    /// Pins one checkpoint: writes the saved machine's bytes into the
    /// object space under the 128-bit truncated SHA-256 of the bytes,
    /// makes them durable with a sync, and only then stages the
    /// Checkpoint record, so the record never names an object the
    /// storage does not hold yet. The staged record leaves at the next
    /// commit, with whatever frames share it.
    pub fn checkpoint(self: *Recorder, header: record.Header, id: u32, bytes: []const u8) anyerror!void {
        try self.pin(.checkpoint, header, id, bytes);
    }

    pub fn checkpointTouched(
        self: *Recorder,
        header: record.Header,
        id: u32,
        bytes: []const u8,
        touched: *const touched_pages.Touched,
    ) anyerror!void {
        try self.pinWithTouched(.checkpoint, header, id, bytes, touched, null);
    }

    /// `checkpointTouched` that also files the checkpoint's encoded
    /// manifest as an object beside it, when one is given.
    pub fn checkpointRecords(
        self: *Recorder,
        header: record.Header,
        id: u32,
        bytes: []const u8,
        touched: ?*const touched_pages.Touched,
        manifest_bytes: ?[]const u8,
    ) anyerror!void {
        try self.pinWithTouched(.checkpoint, header, id, bytes, touched, manifest_bytes);
    }

    /// What a caller needs to undo a group of staged pins that did not
    /// all land (a picture staged, then its checkpoint refused).
    pub const Mark = struct { end: usize, pending: usize, object_bytes: u64 };

    pub fn mark(self: *const Recorder) Mark {
        return .{ .end = self.staging.writer.end, .pending = self.log.pending_bytes, .object_bytes = self.object_bytes };
    }

    /// Unstages every record after `to` and gives back the object bytes
    /// counted since. The objects themselves stay in the object space,
    /// unnamed, for the orphan sweep.
    pub fn rollback(self: *Recorder, to: Mark) void {
        self.staging.writer.end = to.end;
        self.log.pending_bytes = to.pending;
        self.object_bytes = to.object_bytes;
    }

    /// Pins one checkpoint's picture the same way: object first, durable,
    /// then its record. The record is what keeps the object off the orphan
    /// sweep, so a picture the log names is never reclaimed.
    pub fn checkpointPicture(self: *Recorder, header: record.Header, id: u32, bytes: []const u8) anyerror!void {
        try self.pin(.checkpoint_picture, header, id, bytes);
    }

    fn pin(self: *Recorder, kind: record.Kind, header: record.Header, id: u32, bytes: []const u8) anyerror!void {
        return self.pinWithTouched(kind, header, id, bytes, null, null);
    }

    fn pinWithTouched(
        self: *Recorder,
        kind: record.Kind,
        header: record.Header,
        id: u32,
        bytes: []const u8,
        touched: ?*const touched_pages.Touched,
        manifest_bytes: ?[]const u8,
    ) anyerror!void {
        // A replayed round's state is already in the history: neither its
        // object nor its record is written again, nor counted again.
        if (self.replaying or self.stopped) return;
        const objects = self.objects orelse return Error.NoObjects;
        if (self.disk) |watch| {
            _ = try self.checkDisk(watch, self.usedBytes(), bytes.len);
        }
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        var name: [32]u8 = undefined;
        for (digest[0..16], 0..) |byte, i| {
            _ = std.fmt.bufPrint(name[i * 2 ..][0..2], "{x:0>2}", .{byte}) catch unreachable;
        }
        try objects.put(objects.context, &name, bytes);
        if (touched) |t| {
            var touched_buf: std.Io.Writer.Allocating = try .initCapacity(self.gpa, 256);
            defer touched_buf.deinit();
            try t.encode(&touched_buf.writer);
            const t_name = touched_pages.objectName(digest[0..16].*);
            try objects.put(objects.context, &t_name, touched_buf.writer.buffered());
        }
        if (manifest_bytes) |m| {
            const m_name = manifest_mod.objectName(digest[0..16].*);
            try objects.put(objects.context, &m_name, m);
        }
        try objects.sync(objects.context);
        var staging: std.Io.Writer.Allocating = try .initCapacity(self.gpa, 64);
        defer staging.deinit();
        try record.encodeCheckpoint(&staging.writer, header, .{ .id = id, .object = digest[0..16].* });
        try self.stagePayload(@backingInt(kind), staging.writer.buffered());
        self.object_bytes += bytes.len;
    }

    /// The disk-side check both a commit and a checkpoint run: one
    /// fresh free-space read, and on a refusal the application's
    /// relief, once, then one re-check whose answer stands. The relief
    /// crosses as a callback the same way the free-space read does,
    /// because session never touches the host.
    fn usedBytes(self: *const Recorder) u64 {
        return self.history_bytes + self.object_bytes + self.root_bytes;
    }

    fn checkDisk(self: *Recorder, watch: Budget, used: u64, additional: u64) anyerror!budget.Pressure {
        const free = try watch.free(watch.context);
        if (budget.checkCommit(used, additional, watch.cap, free, watch.floor)) |answer| {
            self.last_pressure = answer;
            return answer;
        } else |err| {
            const relieve = watch.relief orelse return err;
            try relieve(watch.context);
            const relieved = try watch.free(watch.context);
            self.last_pressure = try budget.checkCommit(used, additional, watch.cap, relieved, watch.floor);
            return self.last_pressure;
        }
    }

    fn stagePayload(self: *Recorder, kind: u16, payload: []const u8) anyerror!void {
        if (self.replaying or self.stopped) return;
        try format.encode(&self.staging.writer, kind, payload);
        self.log.pending_bytes += format.header_len + payload.len;
    }

    fn stage(self: *Recorder, kind: u16, header: record.Header, what: anytype, body: []const u8) anyerror!void {
        if (self.replaying) return;
        var staging: std.Io.Writer.Allocating = try .initCapacity(self.gpa, 64 + body.len);
        defer staging.deinit();
        try record.encodeBodied(&staging.writer, header, @backingInt(what), body);
        try self.stagePayload(kind, staging.writer.buffered());
    }

    /// Commits at the first of the policy's two thresholds, on the
    /// caller's clock.
    pub fn maybeCommit(self: *Recorder, now_ns: u64) anyerror!void {
        if (!self.log.have_time) self.observe(now_ns);
        if (self.log.shouldCommit(now_ns) == .no) return;
        try self.commit(now_ns);
    }

    /// Hands the log its first time sample without committing.
    pub fn observe(self: *Recorder, now_ns: u64) void {
        self.log.observe(now_ns);
    }

    pub fn bindClock(self: *Recorder, clock: log_mod.Clock) void {
        self.clock = clock;
        self.observe(self.now());
    }

    pub fn now(self: *const Recorder) u64 {
        return if (self.clock) |clock| clock.nowFn(clock.context) else self.log.last_commit_ns;
    }

    /// Flush at a visibility/lifecycle boundary using the caller clock.
    pub fn force(self: *Recorder) anyerror!void {
        try self.commit(self.now());
    }

    /// Preserve staging and thresholds until append and durable flush succeed.
    pub fn commit(self: *Recorder, now_ns: u64) anyerror!void {
        if (self.stopped or self.replaying) return;
        const bytes = self.staging.writer.buffered();
        if (self.disk) |watch| {
            if (self.log.pending_bytes > 0)
                _ = try self.checkDisk(watch, self.usedBytes(), self.log.pending_bytes);
        }
        if (bytes.len == 0) return;
        try self.batch.write(self.storage, self.committed_bytes, bytes);
        self.committed_bytes += bytes.len;
        self.history_bytes += bytes.len;
        self.staging.writer.end = 0;
        self.log.acknowledge(now_ns);
    }

    /// Bytes staged but not yet in the storage's hands.
    pub fn pendingBytes(self: *const Recorder) usize {
        return self.staging.writer.buffered().len;
    }
};
