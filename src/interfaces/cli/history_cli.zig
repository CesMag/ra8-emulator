//! `ra8_emulator history`: the persistent history's command line
//! (RA8EMU-1196, slice 16 M2). The tools open an existing history root of
//! any role and read it; only `rm` and `prune` change it, and both act on
//! single sessions under their own locks, so nothing a live session holds
//! is ever touched. Findings and byte counts go to stdout; complaints go
//! to stderr.
const std = @import("std");
const history = @import("ra8_host").history;
const bind = struct {
    const rpc = @import("ra8_rpc");
    const prune_referrer = rpc.history_bind.prune_referrer;
    const pack_store = rpc.pack_store;
    const history_live = rpc.history_live;
};
const history_branch_cli = @import("history_branch_cli.zig");
const history_maint_cli = @import("history_maint_cli.zig");
const history_replay_elf_cli = @import("history_replay_elf_cli.zig");

pub const usage =
    \\usage: ra8_emulator history --root DIR ls
    \\       ra8_emulator history --root DIR du [SESSION]
    \\       ra8_emulator history --root DIR rm [--kept] SESSION
    \\       ra8_emulator history --root DIR prune
    \\       ra8_emulator history --root DIR thin [--gap ROUNDS] SESSION
    \\       ra8_emulator history --root DIR reroot --confirm SESSION CHECKPOINT_ID
    \\       ra8_emulator history --root DIR branch ls [SESSION]
    \\       ra8_emulator history --root DIR branch rm [--confirm] SESSION BRANCH_ID
    \\       ra8_emulator history --root DIR replay-elf SESSION --elf PATH [--json]
    \\       ls lists the root's entries with their state; du reports bytes,
    \\       all sessions or one; rm removes a session, --kept for a kept
    \\       one; prune sweeps each closed session's orphaned objects and
    \\       leftover frame cache, and never opens a session whose lock
    \\       another host still holds; branch ls lists branches of a session
    \\       or all sessions; branch rm removes a branch with --confirm;
    \\       thin drops checkpoints so none are more than ROUNDS apart
    \\       (default 4096) and reroot drops the history before a checkpoint;
    \\       both then reclaim the dropped objects and compact the packs;
    \\       replay-elf runs the session's recorded inputs against the rebuilt
    \\       ELF at PATH without writing the history, and exits 0 when every
    \\       checkpoint matches and 3 at the first that does not.
    \\
;

pub const BranchSub = union(enum) {
    ls: ?[]const u8,
    rm: struct { session: []const u8, branch_id: u32, confirm: bool },
};

pub const Op = enum { ls, du, rm, prune, branch, thin, reroot, @"replay-elf" };

const Command = struct {
    op: Op,
    root: []const u8,
    entry: ?[]const u8 = null,
    kept: bool = false,
    branch_sub: ?BranchSub = null,
    confirm: bool = false,
    gap: u64 = 4096,
    checkpoint: u32 = 0,
    elf: ?[]const u8 = null,
    json: bool = false,
};

/// The flags come in any order; words name the operation and its target.
pub fn parse(argv: []const []const u8) !Command {
    if (argv.len < 3) return error.Usage;
    var root: []const u8 = "";
    var kept = false;
    var confirm = false;
    var gap: ?u64 = null;
    var elf: ?[]const u8 = null;
    var json = false;
    var words_buf: [8][]const u8 = undefined;
    var words_len: usize = 0;
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--root")) {
            i += 1;
            if (i >= argv.len or root.len != 0) return error.Usage;
            root = argv[i];
        } else if (std.mem.eql(u8, arg, "--kept")) {
            try once(&kept);
        } else if (std.mem.eql(u8, arg, "--gap")) {
            i += 1;
            if (i >= argv.len or gap != null) return error.Usage;
            gap = std.fmt.parseInt(u64, argv[i], 10) catch return error.Usage;
            if (gap.? == 0) return error.Usage;
        } else if (std.mem.eql(u8, arg, "--elf")) {
            if (i + 1 >= argv.len or elf != null) return error.Usage;
            i += 1;
            elf = argv[i];
        } else if (std.mem.eql(u8, arg, "--json")) {
            try once(&json);
        } else if (std.mem.eql(u8, arg, "--confirm")) {
            try once(&confirm);
        } else {
            if (words_len >= words_buf.len) return error.Usage;
            words_buf[words_len] = arg;
            words_len += 1;
        }
    }
    if (root.len == 0 or words_len == 0) return error.Usage;
    const words = words_buf[0..words_len];
    const op = std.meta.stringToEnum(Op, words[0]) orelse return error.Usage;
    if ((elf != null or json) and op != .@"replay-elf") return error.Usage;
    var command = Command{ .op = op, .root = root, .kept = kept };

    switch (op) {
        .ls, .prune => {
            if (kept or confirm or words.len > 1) return error.Usage;
        },
        .du => {
            if (kept or confirm or words.len > 2) return error.Usage;
            if (words.len == 2) command.entry = words[1];
        },
        .rm => {
            if (confirm or words.len != 2) return error.Usage;
            command.entry = words[1];
        },
        .thin => {
            if (kept or confirm or words.len != 2) return error.Usage;
            command.entry = words[1];
            command.gap = gap orelse command.gap;
        },
        .reroot => {
            if (kept or gap != null or words.len != 3) return error.Usage;
            command.entry = words[1];
            command.checkpoint = std.fmt.parseInt(u32, words[2], 10) catch return error.Usage;
            command.confirm = confirm;
        },
        .@"replay-elf" => {
            if (kept or confirm or gap != null or words.len != 2) return error.Usage;
            command.entry = words[1];
            command.elf = elf orelse return error.Usage;
            command.json = json;
        },
        .branch => {
            if (kept or gap != null or words.len < 2) return error.Usage;
            command.branch_sub = try branchSub(words, confirm);
        },
    }
    return command;
}

/// A flag that may be given once.
fn once(seen: *bool) !void {
    if (seen.*) return error.Usage;
    seen.* = true;
}

fn branchSub(words: []const []const u8, confirm: bool) !BranchSub {
    if (std.mem.eql(u8, words[1], "ls")) {
        if (words.len > 3 or confirm) return error.Usage;
        return .{ .ls = if (words.len == 3) words[2] else null };
    }
    if (!std.mem.eql(u8, words[1], "rm") or words.len != 4) return error.Usage;
    const b_id = std.fmt.parseInt(u32, words[3], 0) catch return error.Usage;
    return .{ .rm = .{ .session = words[2], .branch_id = b_id, .confirm = confirm } };
}

/// The root the flags name, in the role its own marker claims. The tools
/// try every role rather than one, so a single command line serves cache
/// and kept roots alike; a directory with no marker is refused, never
/// adopted.
fn openRoot(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !history.base.Base {
    const absolute = try absolutePath(allocator, io, path);
    defer allocator.free(absolute);
    inline for (.{ .cache, .kept, .runtime }) |role| {
        if (history.base.Base.existing(allocator, io, absolute, role)) |found| {
            return found;
        } else |err| switch (err) {
            error.WrongRole => {},
            else => return err,
        }
    }
    return error.Unmarked;
}

/// A root path the command line took may be relative; the history root
/// itself must be absolute, so resolve here and once.
fn absolutePath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.cwd().realPath(io, &buffer);
    return std.fs.path.join(allocator, &.{ buffer[0..len], path });
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !u8 {
    const command = parse(argv) catch {
        std.Io.File.stderr().writeStreamingAll(io, usage) catch {};
        return 2;
    };
    var base = try openRoot(allocator, io, command.root);
    defer base.close();
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const outcome = switch (command.op) {
        .ls => listRoot(&base, &stdout.interface),
        .du => reportBytes(&base, &stdout.interface, command.entry),
        .rm => removeOne(&base, &stdout.interface, command.entry.?, command.kept),
        .prune => sweepClosed(allocator, &base, &stdout.interface),
        .thin => history_maint_cli.thin(allocator, &base, command.entry.?, false, command.gap, &stdout.interface),
        .reroot => history_maint_cli.reroot(allocator, &base, command.entry.?, false, command.checkpoint, command.confirm, &stdout.interface),
        .@"replay-elf" => history_replay_elf_cli.run(allocator, io, &base, command.entry.?, command.elf.?, command.json, &stdout.interface),
        .branch => switch (command.branch_sub.?) {
            .ls => |session_name| history_branch_cli.listBranches(allocator, &base, session_name, &stdout.interface),
            .rm => |b_rm| history_branch_cli.removeBranch(allocator, &base, b_rm.session, b_rm.branch_id, b_rm.confirm, &stdout.interface),
        },
    };
    try stdout.interface.flush();
    return outcome catch |err| {
        std.debug.print("history: {s}\n", .{@errorName(err)});
        return 1;
    };
}

/// One line per entry the root holds: name, kind, and the state the
/// catalog read out of it, with kept flags and pointer targets after.
pub fn listRoot(base: *const history.base.Base, out: *std.Io.Writer) !u8 {
    var entries = try history.catalog.Iterator.init(base);
    while (try entries.next()) |entry| {
        try out.print("{s} {s} {s}", .{ entry.name, @tagName(entry.kind), @tagName(entry.status) });
        if (entry.kept) try out.writeAll(" kept");
        if (entry.pointer) |target| try out.print(" -> {s}", .{target});
        try out.writeAll("\n");
    }
    return 0;
}

/// The bytes an entry holds, or every session's bytes plus the total when
/// no session was named.
pub fn reportBytes(base: *const history.base.Base, out: *std.Io.Writer, entry: ?[]const u8) !u8 {
    if (entry) |name| {
        try out.print("{s} {d}\n", .{ name, try history.catalog.du(base, name) });
        return 0;
    }
    var total: u64 = 0;
    var entries = try history.catalog.Iterator.init(base);
    while (try entries.next()) |item| {
        if (item.kind != .session) continue;
        const bytes = try history.catalog.du(base, item.name);
        total += bytes;
        try out.print("{s} {d}\n", .{ item.name, bytes });
    }
    try out.print("total {d}\n", .{total});
    return 0;
}

/// Explicit rm: never a live or foreign session, and a kept one only when
/// `--kept` said so. The lifecycle module enforces both.
pub fn removeOne(base: *const history.base.Base, out: *std.Io.Writer, entry: []const u8, kept: bool) !u8 {
    try history.remove.entryRemove(base, entry, .{ .allow_kept = kept });
    try out.print("removed {s}\n", .{entry});
    return 0;
}

/// The quiescent prune: every closed session the root holds, swept one at
/// a time under its own session lock. A session whose sweep fails is
/// reported and the rest go on; the exit says the run was not clean.
pub fn sweepClosed(allocator: std.mem.Allocator, base: *const history.base.Base, out: *std.Io.Writer) !u8 {
    var failed = false;
    var entries = try history.catalog.Iterator.init(base);
    while (try entries.next()) |entry| {
        const closed = entry.status == .stale or entry.status == .kept;
        if (entry.kind != .session or !closed) continue;
        sweepSession(allocator, base, entry.name, entry.kept, out) catch |err| {
            failed = true;
            try out.print("{s}: {s}\n", .{ entry.name, @errorName(err) });
        };
    }
    return if (failed) 1 else 0;
}

/// One session's sweep: the session lock held, renames settled, the
/// orphan sweep walking the committed log through the RPC bind's
/// referrer, then the frame cache. The session is never closed, so an
/// ephemeral one stays exactly where it is; the lock file and the open
/// directory are all this touch leaves behind.
fn sweepSession(allocator: std.mem.Allocator, base: *const history.base.Base, name: []const u8, kept: bool, out: *std.Io.Writer) !void {
    var dir = try base.dir.openDir(base.io, name, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(base.io);
    var id: history.name.Id = undefined;
    @memcpy(&id, history.name.classify(name).id);
    const held = (try history.lock.take(base.io, base.dir, &id)) orelse return;
    defer held.close(base.io);
    try history.rename.settle(base.io, dir);
    // The storage adapter reads only the session's base, id, dir and
    // lock, so a closed session's sweep goes through the same Store the
    // live recorder uses, with no second adapter to keep honest.
    var session = history.session.Session{ .base = base, .id = id, .dir = dir, .lock = held, .kept = kept };
    const store = history.storage.Store.from(&session);
    const res = try history.prune.relief(store, allocator, bind.prune_referrer);
    try out.print("{s}: {d} orphan objects ({d} bytes), {d} frames ({d} bytes)\n", .{ name, res.orphans, res.orphan_bytes, res.frames, res.frame_bytes });
    // The pack step: packs more than 30% dead are rewritten.
    const packs = try bind.pack_store.PackStore.open(allocator, &session);
    defer packs.close();
    const compacted = try bind.history_live.compactPacks(store, allocator, packs, bind.prune_referrer.collect);
    try out.print("{s}: {d} packs compacted ({d} -> {d} bytes)\n", .{ name, compacted.packs_removed, compacted.bytes_before, compacted.bytes_after });
}
