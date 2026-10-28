//! The event log's records: the frozen kind table, the shape every record
//! shares, and the codecs of the records themselves.
//!
//! Every record but the root opens with the scheduler position it happened
//! at and a source sequence number. The position says where in the run the
//! record sits; the sequence keeps events that share a position in the
//! order they were recorded, monotonic across the whole log. Which kinds
//! exist is this table, frozen on disk: the frame kind's top bit says
//! whether an unknown kind is mandatory, a hard error for a reader that
//! predates it, or optional, kept and skipped. A record body a reader does
//! not know is kept and skipped the same way, never dropped.
//!
//! Records record events, not slots: their count scales with what the
//! host and the boundaries did, never with how many instructions ran.

const std = @import("std");
const history_position = @import("position.zig");
const scheduler = @import("ra8_chip").core.scheduler;

pub const Position = history_position.Position;

/// The frame kind's top bit. Set, an unknown kind is mandatory: a reader
/// that does not know it fails the log rather than skipping it. Clear, an
/// unknown kind is skipped and counted.
pub const mandatory_bit: u16 = 0x8000;

/// Whether a frame kind carries the mandatory bit.
pub fn mandatory(kind: u16) bool {
    return kind & mandatory_bit != 0;
}

/// Whether this table knows a frame kind, mandatory bit aside.
pub fn known(kind: u16) bool {
    return switch (kind & ~mandatory_bit) {
        @backingInt(Kind.root),
        @backingInt(Kind.branch),
        @backingInt(Kind.checkpoint),
        @backingInt(Kind.intervention),
        @backingInt(Kind.boundary),
        @backingInt(Kind.checkpoint_picture),
        => true,
        else => false,
    };
}

/// The record kinds. The kind value is the frame kind without the
/// mandatory bit; the numbers are frozen.
pub const Kind = enum(u16) {
    /// The history's opening record; its body is root.zig's codec.
    root = 1,
    /// A line forked from another.
    branch = 2,
    /// A checkpoint pinned a saved machine object.
    checkpoint = 3,
    /// A host-originated mutation crossed a dispatching boundary.
    intervention = 4,
    /// An external event landed at its boundary.
    boundary = 5,
    /// A checkpoint's picture pinned an object: the composited last scan at
    /// or before the checkpoint. The body is the checkpoint record's shape.
    checkpoint_picture = 6,
    _,
};

pub const Error = error{ BadValue, Truncated };

/// The shape every record but the root shares: where it happened, and its
/// order among events at the same position.
pub const Header = struct {
    position: Position,
    seq: u32,
};

/// The record header's wire size: the position's bytes plus the sequence.
pub const header_len: usize = history_position.encoded_len + 4;

fn encodeHeader(writer: anytype, header: Header) !void {
    try history_position.encode(writer, header.position);
    try writer.writeInt(u32, header.seq, .little);
}

fn decodeHeader(payload: []const u8, at: *usize) Error!Header {
    const position = history_position.decode(payload, at) catch |err| switch (err) {
        error.BadValue => return Error.BadValue,
        else => return Error.Truncated,
    };
    const seq = readInt(u32, payload, at) orelse return Error.Truncated;
    return .{ .position = position, .seq = seq };
}

fn readInt(comptime T: type, payload: []const u8, at: *usize) ?T {
    const span = @sizeOf(T);
    if (payload.len - at.* < span) return null;
    const raw = payload[at.*..][0..span];
    at.* += span;
    return std.mem.readInt(T, raw, .little);
}

/// Why a line forked, from the design's fork triggers.
pub const ForkReason = enum(u8) {
    /// The history's base line, which has no parent.
    base = 0,
    writes = 1,
    taps = 2,
    buttons = 3,
    keystrokes = 4,
    plug_unplug_fault = 5,
    camera_change = 6,
    skip_bkpt = 7,
    load = 8,
};

pub const Branch = struct {
    id: u32,
    /// The line this one forked from; 0 names the history's base line,
    /// which has no parent.
    parent: u32,
    /// Where the fork left the parent's line; the base line's is zeroed.
    fork_at: Position,
    reason: ForkReason,
};

pub const BranchRecord = struct { header: Header, branch: Branch };

pub fn encodeBranch(writer: anytype, header: Header, branch: Branch) !void {
    try encodeHeader(writer, header);
    try writer.writeInt(u32, branch.id, .little);
    try writer.writeInt(u32, branch.parent, .little);
    try history_position.encode(writer, branch.fork_at);
    try writer.writeByte(@backingInt(branch.reason));
}

pub fn decodeBranch(payload: []const u8) Error!BranchRecord {
    var at: usize = 0;
    const header = try decodeHeader(payload, &at);
    const id = readInt(u32, payload, &at) orelse return Error.Truncated;
    const parent = readInt(u32, payload, &at) orelse return Error.Truncated;
    const fork_at = try decodePosition(payload, &at);
    const reason = readInt(u8, payload, &at) orelse return Error.Truncated;
    if (reason > @backingInt(ForkReason.load)) return Error.BadValue;
    return .{
        .header = header,
        .branch = .{ .id = id, .parent = parent, .fork_at = fork_at, .reason = @fromBackingInt(@intCast(reason)) },
    };
}

fn decodePosition(payload: []const u8, at: *usize) Error!Position {
    return history_position.decode(payload, at) catch |err| switch (err) {
        error.BadValue => return Error.BadValue,
        else => return Error.Truncated,
    };
}

/// One checkpoint's record: which checkpoint, and which object holds the
/// saved machine. The object identity is a 128-bit truncated hash. The
/// object must exist and hash-match before this record is visible; that
/// ordering is the storage layer's rule to prove, not this codec's.
pub const Checkpoint = struct {
    id: u32,
    object: [16]u8,
};

pub const CheckpointRecord = struct { header: Header, checkpoint: Checkpoint };

pub fn encodeCheckpoint(writer: anytype, header: Header, checkpoint: Checkpoint) !void {
    try encodeHeader(writer, header);
    try writer.writeInt(u32, checkpoint.id, .little);
    try writer.writeAll(&checkpoint.object);
}

pub fn decodeCheckpoint(payload: []const u8) Error!CheckpointRecord {
    var at: usize = 0;
    const header = try decodeHeader(payload, &at);
    const id = readInt(u32, payload, &at) orelse return Error.Truncated;
    if (payload.len - at < 16) return Error.Truncated;
    var object: [16]u8 = undefined;
    @memcpy(&object, payload[at..][0..16]);
    at += 16;
    return .{ .header = header, .checkpoint = .{ .id = id, .object = object } };
}

/// A checkpoint picture's record: the checkpoint it belongs to and the
/// object holding the picture. It shares the checkpoint record's shape, and
/// being a committed record is what keeps the orphan sweep off the object.
pub fn encodeCheckpointPicture(writer: anytype, header: Header, picture: Checkpoint) !void {
    try encodeCheckpoint(writer, header, picture);
}

pub fn decodeCheckpointPicture(payload: []const u8) Error!CheckpointRecord {
    return decodeCheckpoint(payload);
}

/// A host-originated mutation through the UI or RPC, logged at the
/// dispatching boundary it crossed. The body is the mutation's own
/// detail; its codec belongs to the subsystem that emits it.
pub const Intervention = struct {
    pub const What = enum(u16) {
        tap = 1,
        button = 2,
        keystroke = 3,
        rpc_mutation = 4,
        register_write = 5,
        memory_write = 6,
        plug = 7,
        unplug = 8,
        fault = 9,
        camera_change = 10,
        skip_bkpt = 11,
        load = 12,
        _,
    };
    what: What,
    /// The mutation's own bytes, borrowed from the payload they were read
    /// from. An unknown `what` still decodes: the record is kept, and a
    /// reader that cannot interpret it skips it.
    body: []const u8,
};

pub const InterventionRecord = struct { header: Header, intervention: Intervention };

pub fn encodeIntervention(writer: anytype, header: Header, intervention: Intervention) !void {
    try encodeBodied(writer, header, @backingInt(intervention.what), intervention.body);
}

pub fn decodeIntervention(payload: []const u8) Error!InterventionRecord {
    const hit = try decodeBodied(Intervention.What, payload);
    return .{ .header = hit.header, .intervention = .{ .what = hit.what, .body = hit.body } };
}

/// An external event at the boundary where it landed. The body is the
/// event's own detail, owned by the subsystem that emitted it.
pub const Boundary = struct {
    pub const What = enum(u16) {
        c6_bytes = 1,
        c6_answer = 2,
        camera_change = 3,
        plug = 4,
        unplug = 5,
        fault = 6,
        skip_bkpt = 7,
        load = 8,
        /// A scripted tap, swipe or long press reached the panel. The
        /// intervention that scheduled it is what replay re-applies; the
        /// landing is the observation of where it took effect.
        tap_landed = 9,
        button_landed = 10,
        /// One frame the CEU captured from the camera source, at the
        /// position the capture armed. Unlike a landing it is an input
        /// replay re-feeds: the body is camera_frame.zig's record.
        camera_frame = 11,
        _,
    };
    what: What,
    body: []const u8,
};

pub const BoundaryRecord = struct { header: Header, boundary: Boundary };

pub fn encodeBoundary(writer: anytype, header: Header, boundary: Boundary) !void {
    try encodeBodied(writer, header, @backingInt(boundary.what), boundary.body);
}

pub fn decodeBoundary(payload: []const u8) Error!BoundaryRecord {
    const hit = try decodeBodied(Boundary.What, payload);
    return .{ .header = hit.header, .boundary = .{ .what = hit.what, .body = hit.body } };
}

// The body every record but the root shares, public for the recorder which
// stages the same payload shape into its frames.
pub fn encodeBodied(writer: anytype, header: Header, what: u16, body: []const u8) !void {
    try encodeHeader(writer, header);
    try writer.writeInt(u16, what, .little);
    try writer.writeInt(u32, @intCast(body.len), .little);
    try writer.writeAll(body);
}

fn Bodied(comptime What: type) type {
    return struct { header: Header, what: What, body: []const u8 };
}

fn decodeBodied(comptime What: type, payload: []const u8) Error!Bodied(What) {
    var at: usize = 0;
    const header = try decodeHeader(payload, &at);
    const what = readInt(u16, payload, &at) orelse return Error.Truncated;
    const body_len = readInt(u32, payload, &at) orelse return Error.Truncated;
    if (payload.len - at < body_len) return Error.Truncated;
    const body = payload[at..][0..body_len];
    at += body_len;
    return .{ .header = header, .what = @fromBackingInt(@intCast(what)), .body = body };
}
