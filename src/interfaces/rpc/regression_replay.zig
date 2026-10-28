//! Explicit regression replay (row 24): a recorded history is opened
//! read-only, a rebuilt ELF is run in its place, and the recorded inputs
//! (the interventions and every landed source) are replayed against it.
//! The trajectory is compared with the history's own checkpoints, by state
//! digest at each one, and the first checkpoint that differs is reported
//! with where it differs.
//!
//! The recorded history is never written: no session lock is taken, no
//! file is created, and the machine that replays is a separate RAM-only
//! session over the rebuilt image. This is not what loading a different
//! image does; that starts a new history (session/new_history.zig).
//!
//! Only the history's root line is replayed, and a history that recorded
//! a second core is refused: the replay machine is one core.
const std = @import("std");
const session_lib = @import("ra8_session");
const history = @import("ra8_host").history;
const served_setup = @import("served_setup.zig");
const history_segments = @import("history_segments.zig");
const object_read = @import("object_read.zig");
const transport = session_lib.transport;

const elf = @import("ra8_board").image.elf;
const branch = session_lib.history_branch;
const elf_compare = session_lib.history_elf_compare;
const seek_engine = session_lib.history_seek_engine;
const seek_facts = session_lib.history_seek_facts;
const history_root = session_lib.history_root;
const state_digest = session_lib.history_state_digest;
const symbols = session_lib.symbols;
const Position = session_lib.history_position.Position;

pub const Error = error{
    /// The history recorded a second core; the replay machine is one core.
    SecondCoreRecorded,
    /// The session holds no root record to take its image from.
    NoRoot,
    /// A checkpoint the log names has no object to compare against.
    ObjectMissing,
};

pub const Verdict = enum { compatible, diverged };

/// A function symbol and how far into it an address sits.
pub const Symbol = struct { name: []const u8, offset: u32 };

/// The first checkpoint at which the rebuilt run is not the recorded one.
pub const Divergence = struct {
    /// The checkpoint's id and position in the recorded history.
    checkpoint: u32,
    position: Position,
    core: u8,
    pc_expected: u32,
    pc_actual: u32,
    /// What differs first; null when the rebuilt run stopped before it
    /// reached the checkpoint, and `stopped` says how.
    place: ?state_digest.Place,
    stopped: ?[]const u8,
    /// The rebuilt image's function around `pc_actual`, when it has one.
    symbol: ?Symbol,
};

pub const Result = struct {
    arena: *std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    verdict: Verdict,
    /// The recorded line's checkpoints, and how many matched in order.
    checkpoints: u32,
    matched: u32,
    /// The last round the replay reached.
    round: u64,
    elf: elf_compare.Report,
    divergence: ?Divergence,

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
        self.gpa.destroy(self.arena);
    }
};

/// What the caller may hook into the replay machine before it runs, such
/// as a bridge that stands in for a recorded host.
pub const Prepare = struct {
    context: *anyopaque,
    prepareFn: *const fn (context: *anyopaque, served: *served_setup.Served, log: []const u8) anyerror!void,
};

pub const Options = struct {
    prepare: ?Prepare = null,
    /// The RAM the replay machine may use; null sizes it from the host.
    ram_budget: u64 = 256 * 1024 * 1024,
};

/// A checkpoint count no run reaches: the replay machine takes none of its own.
const never: u32 = std.math.maxInt(u32);

/// Replays the session `name` of `base` against the ELF at `rebuilt_path`.
pub fn run(allocator: std.mem.Allocator, io: std.Io, base: *const history.base.Base, name: []const u8, rebuilt_path: []const u8, options: Options) !Result {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer allocator.destroy(arena);
    errdefer arena.deinit();
    const keep = arena.allocator();
    var dir = try base.dir.openDir(io, name, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    // The store reads only the session's base, id and directory. The lease
    // field is for writers; a read-only open never takes it.
    var opened: history.session.Session = .{ .base = base, .id = try history.name.id(name), .dir = dir, .lock = undefined };
    const store = history.storage.Store.from(&opened);
    const root_bytes = (try history.branches_file.readAlloc(io, dir, history.layout.files.root, keep)) orelse return Error.NoRoot;
    const root = try history_root.decode(root_bytes);
    if (root.elf1 != null) return Error.SecondCoreRecorded;
    const log = try history_segments.readAll(keep, store);
    const rebuilt = try std.Io.Dir.cwd().readFileAlloc(io, rebuilt_path, keep, .limited(history_root.max_elf));
    const found = try seek_facts.gather(allocator, log);
    defer allocator.free(found.checkpoints);
    const line = try rootLine(keep, found.checkpoints);

    var served: served_setup.Served = undefined;
    try served.open(allocator, io, rebuilt_path, null, .{ .ram_budget = options.ram_budget, .checkpoint_every = never });
    defer served.deinit();
    if (options.prepare) |hook| try hook.prepareFn(hook.context, &served, log);
    const session = served.owner.session();
    try session.loadReplayInterventions(log);
    session.setReplaying(true);

    var result: Result = .{
        .arena = arena,
        .gpa = allocator,
        .verdict = .compatible,
        .checkpoints = @intCast(line.len),
        .matched = 0,
        .round = 0,
        .elf = try elf_compare.compare(allocator, root.elf0.bytes, rebuilt),
        .divergence = null,
    };
    const images = Images{ .original = try elf.Image.init(root.elf0.bytes), .rebuilt = served.owner.image() };
    for (line) |checkpoint| {
        if (try compareAt(allocator, keep, &served, store, images, checkpoint, &result)) break;
    }
    return result;
}

const Images = struct { original: elf.Image, rebuilt: elf.Image };

/// The checkpoints of the root line in position order.
fn rootLine(keep: std.mem.Allocator, all: []const seek_engine.Checkpoint) ![]const seek_engine.Checkpoint {
    var line: std.ArrayList(seek_engine.Checkpoint) = .empty;
    for (all) |c| {
        if (c.position.branch == branch.root_branch_id) try line.append(keep, c);
    }
    std.mem.sort(seek_engine.Checkpoint, line.items, {}, before);
    return line.items;
}

fn before(_: void, a: seek_engine.Checkpoint, b: seek_engine.Checkpoint) bool {
    const order = Position.order(a.position, b.position) orelse .eq;
    return order == .lt or (order == .eq and a.id < b.id);
}

/// Brings the replay machine to one checkpoint and compares it. True when
/// the run is over: it diverged here, and `result` says how.
fn compareAt(allocator: std.mem.Allocator, keep: std.mem.Allocator, served: *served_setup.Served, store: history.storage.Store, images: Images, checkpoint: seek_engine.Checkpoint, result: *Result) !bool {
    var name: [32]u8 = undefined;
    transport.objectName(checkpoint.object, &name);
    const recorded = object_read.read(store, allocator, &name) catch return Error.ObjectMissing;
    defer allocator.free(recorded);
    const session = served.owner.session();
    var stream: std.Io.Writer.Allocating = .init(allocator);
    defer stream.deinit();
    const stopped = try advance(served, checkpoint.position, &stream);
    result.round = session.currentPosition().r;
    // The state is taken where the history took it, as the round opens;
    // a machine that never got there, or is already there, is taken as it stands.
    if (stream.written().len == 0) try session.history.?.files.writeTo(&stream.writer);
    const have = stream.written();
    if (stopped == null and std.mem.eql(u8, &(try state_digest.digest(recorded, images.original)), &(try state_digest.digest(have, images.rebuilt)))) {
        result.matched += 1;
        return false;
    }
    result.verdict = .diverged;
    const found = try state_digest.first(recorded, images.original, have, images.rebuilt);
    const core: u8 = if (found) |f| f.core else 0;
    const pc_expected = if (found) |f| f.pc_expected else try state_digest.pcOf(recorded, 0);
    const pc_actual = if (found) |f| f.pc_actual else try state_digest.pcOf(have, 0);
    result.divergence = .{
        .checkpoint = checkpoint.id,
        .position = checkpoint.position,
        .core = core,
        .pc_expected = pc_expected,
        .pc_actual = pc_actual,
        .place = if (found) |f| f.place else null,
        .stopped = if (stopped) |tag| try keep.dupe(u8, tag) else null,
        .symbol = try symbolAt(keep, images.rebuilt, pc_actual),
    };
    return true;
}

fn symbolAt(keep: std.mem.Allocator, image: elf.Image, pc: u32) !?Symbol {
    const found = symbols.inside(image, pc & ~@as(u32, 1)) orelse return null;
    return .{ .name = try keep.dupe(u8, found.name), .offset = found.offset };
}

/// Runs the replay machine to the round `target` names, or until it stops
/// for another reason; null when it got there, else the stop's name.
fn advance(served: *served_setup.Served, target: Position, stream: *std.Io.Writer.Allocating) !?[]const u8 {
    const session = served.owner.session();
    const rounds = session.live.checkpoints orelse return error.NoRounds;
    var halt: HaltAt = .{ .session = session, .round = target.r, .stream = stream };
    rounds.stop = .{ .context = &halt, .roundFn = HaltAt.fire };
    defer rounds.stop = null;
    while (session.currentPosition().r < target.r) {
        switch (try session.run(.cpu0, .cont)) {
            .count => {},
            .stop => |stop| switch (stop) {
                .halt_requested => {},
                else => return @tagName(stop),
            },
            .core => return "core_fault",
        }
    }
    return null;
}

/// Takes the machine's state as the target's round opens, the moment the
/// history took its own checkpoint there, and halts the run.
const HaltAt = struct {
    session: *session_lib.api.Session,
    round: u64,
    stream: *std.Io.Writer.Allocating,

    fn fire(context: *anyopaque, at: Position) void {
        const self: *HaltAt = @ptrCast(@alignCast(context));
        if (at.r < self.round) return;
        if (at.r == self.round) self.session.history.?.files.writeTo(&self.stream.writer) catch {};
        self.session.live.machine.requestHalt();
    }
};
