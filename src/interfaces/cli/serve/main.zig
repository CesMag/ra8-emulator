//! `ra8_emulator serve` (RA8EMU-737, RA8EMU-736): a headless session server.
//!
//! It opens the ELF through served_setup and answers session RPC
//! frames on stdin/stdout (--stdio) or on one socket client at a time
//! (--listen). Frames are the only thing written to stdout; complaints go
//! to stderr.
const std = @import("std");
const served_setup = @import("ra8_rpc").served_setup;
const loop = @import("loop.zig");
const listen = @import("listen.zig");
const card_setup = @import("../card/setup.zig");
const card_apps = @import("ra8_rpc").card_apps;
const txm_debug = @import("ra8_session").txm.debug;
const session_api = @import("ra8_session").api;
const elf = @import("ra8_board").image.elf;
const usbip_run = @import("ra8_usbip").exported.run;

pub const usage =
    \\usage: ra8_emulator serve [--profile-folded] [--cpu1 CPU1.elf] --stdio <firmware.elf>
    \\       ra8_emulator serve [--profile-folded] [--cpu1 CPU1.elf] [--allow-state-files] --listen unix:PATH|tcp:[HOST]:PORT <firmware.elf>
    \\       --profile-folded samples each core's call stacks for `ctl folded`
    \\       --cpu1 brings CPU1 up from its own image, parked until it is run
    \\       --sd-dir DIR and --app FILE.ra8app[=MODULE.elf] (repeatable) fill the SDHI card, as for a run
    \\       --allow-state-files lets snapshot and restore run on a non-loopback listener
    \\       --history DIR puts the session's persistent history in DIR; --history off keeps it RAM only
    \\       --kept preserves the session on disk after exit (with --history DIR)
    \\       --checkpoint-every N writes a closed-round checkpoint every N rounds (default 64)
    \\       --history-budget BYTES caps the served session's history share (with --history DIR; minimum 128 MiB)
    \\       --frame-hz N caps the frame tap at N captures per host second (0 captures every change; default 60)
    \\       --ram-budget BYTES caps the RAM-only history's share (with --history off; minimum 128 MiB)
    \\
;

const Where = union(enum) { stdio, listen: listen.Spec };
const Asked = struct { where: Where, elf: []const u8, folded: bool = false, cpu1: ?[]const u8 = null, sdhi: card_setup.Sdhi = .{}, allow_state_files: bool = false, history: ?[]const u8 = null, history_off: bool = false, checkpoint_every: u32 = 64, history_budget: ?u64 = null, ram_budget: ?u64 = null, kept: bool = false, reopen: ?[]const u8 = null, frame_hz: ?u32 = null, usbip: ?u16 = null };

/// Samples taken one every this many instructions under --profile-folded.
pub const fold_every: u32 = 1000;

/// The transport and image `argv` asks for, or null for a malformed line.
/// The options come first, in any order, each at most once.
pub fn parse(argv: []const []const u8) ?Asked {
    if (argv.len < 2) return null;
    var folded = false;
    var allow_state = false;
    var cpu1: ?[]const u8 = null;
    var sdhi: card_setup.Sdhi = .{};
    var history_root: ?[]const u8 = null;
    var history_off = false;
    var kept = false;
    var reopen: ?[]const u8 = null;
    var frame_hz: ?u32 = null;
    var usbip: ?u16 = null;
    var checkpoint_every: u32 = 64;
    var history_budget: ?u64 = null;
    var ram_budget: ?u64 = null;
    var checkpoint_set = false;
    var at: usize = 2;
    while (at < argv.len) : (at += 1) {
        const valued = at + 1 < argv.len;
        if (std.mem.eql(u8, argv[at], "--profile-folded") and !folded) {
            folded = true;
        } else if (std.mem.eql(u8, argv[at], "--allow-state-files") and !allow_state) {
            allow_state = true;
        } else if (std.mem.eql(u8, argv[at], "--cpu1") and cpu1 == null and valued) {
            at += 1;
            cpu1 = argv[at];
        } else if (std.mem.eql(u8, argv[at], "--sd-dir") and sdhi.dir == null and valued) {
            at += 1;
            sdhi.dir = argv[at];
        } else if (std.mem.eql(u8, argv[at], "--app") and valued) {
            at += 1;
            sdhi.addApp(argv[at]) catch return null;
        } else if (std.mem.eql(u8, argv[at], "--history") and history_root == null and !history_off and valued) {
            at += 1;
            if (std.mem.eql(u8, argv[at], "off")) history_off = true else history_root = argv[at];
        } else if (std.mem.eql(u8, argv[at], "--kept") and !kept) {
            kept = true;
        } else if (std.mem.eql(u8, argv[at], "--frame-hz") and frame_hz == null and valued) {
            at += 1;
            frame_hz = std.fmt.parseInt(u32, argv[at], 10) catch return null;
        } else if (std.mem.eql(u8, argv[at], "--usbip") and usbip == null and valued) {
            at += 1;
            usbip = std.fmt.parseInt(u16, argv[at], 10) catch return null;
        } else if (std.mem.eql(u8, argv[at], "--reopen") and reopen == null and valued) {
            at += 1;
            reopen = argv[at];
        } else if (std.mem.eql(u8, argv[at], "--checkpoint-every") and !checkpoint_set and valued) {
            at += 1;
            checkpoint_every = std.fmt.parseInt(u32, argv[at], 10) catch return null;
            checkpoint_set = true;
        } else if (std.mem.eql(u8, argv[at], "--history-budget") and history_budget == null and valued) {
            at += 1;
            history_budget = std.fmt.parseInt(u64, argv[at], 10) catch return null;
        } else if (std.mem.eql(u8, argv[at], "--ram-budget") and ram_budget == null and valued) {
            at += 1;
            ram_budget = std.fmt.parseInt(u64, argv[at], 10) catch return null;
        } else break;
    }
    var asked = parseTail(argv, at) orelse return null;
    asked.folded = folded;
    asked.allow_state_files = allow_state;
    asked.history = history_root;
    asked.history_off = history_off;
    asked.history_budget = history_budget;
    asked.ram_budget = ram_budget;
    asked.checkpoint_every = checkpoint_every;
    asked.cpu1 = cpu1;
    asked.sdhi = sdhi;
    asked.kept = kept;
    asked.reopen = reopen;
    asked.frame_hz = frame_hz;
    asked.usbip = usbip;
    return if (consistent(asked)) asked else null;
}

/// The transport and image after the options: they are dropped, so the
/// transport sits at index 2 as before.
fn parseTail(argv: []const []const u8, at: usize) ?Asked {
    var rest: [5][]const u8 = undefined;
    const left = argv.len - at;
    if (left > 3) return null;
    rest[0] = argv[0];
    rest[1] = argv[1];
    @memcpy(rest[2..][0..left], argv[at..]);
    return parseWhere(rest[0 .. 2 + left]);
}

/// Whether the history options make sense together.
fn consistent(asked: Asked) bool {
    // A cap means nothing without a persistent history to cap.
    if (asked.history_budget != null and asked.history == null) return false;
    // Kept means nothing without a persistent history.
    if (asked.kept and asked.history == null) return false;
    // A reopened session is one already on disk.
    if (asked.reopen != null and (asked.history == null or asked.kept)) return false;
    // A RAM share cap means nothing without a RAM-only history to cap.
    return asked.ram_budget == null or asked.history_off;
}

fn parseWhere(argv: []const []const u8) ?Asked {
    if (argv.len == 4 and std.mem.eql(u8, argv[2], "--stdio")) return .{ .where = .stdio, .elf = argv[3] };
    if (argv.len != 5 or !std.mem.eql(u8, argv[2], "--listen")) return null;
    const spec = listen.Spec.parse(argv[3]) catch return null;
    return .{ .where = .{ .listen = spec }, .elf = argv[4] };
}

/// Each paired app's display name and module ELF, as the session places them.
/// Places and clears real breakpoints for breaks named before their
/// module loaded, through the served session (RA8EMU-1141).
const BreakArmer = struct {
    session: *session_api.Session,
    fn arm(ctx: *anyopaque, of: txm_debug.Core, address: u32) anyerror!u32 {
        const self: *BreakArmer = @ptrCast(@alignCast(ctx));
        return self.session.setBreakpoint(of, .{ .address = address });
    }
    fn drop(ctx: *anyopaque, of: txm_debug.Core, id: u32) anyerror!void {
        const self: *BreakArmer = @ptrCast(@alignCast(ctx));
        return self.session.clearBreakpoint(of, id);
    }
};

/// Serve `argv` (`ra8_emulator serve ...`) and return the exit code.
pub fn run(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !u8 {
    const asked = parse(argv) orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    // Declared before the session so the bridge outlives the session's release of it.
    var bridges = std.heap.ArenaAllocator.init(allocator);
    defer bridges.deinit();
    var setup: served_setup.Served = undefined;
    const history_opts: ?served_setup.HistoryOpts = if (asked.history) |root|
        .{ .root = root, .checkpoint_every = asked.checkpoint_every, .budget = asked.history_budget, .kept = asked.kept, .reopen = asked.reopen, .frame_hz = asked.frame_hz }
    else if (asked.history_off)
        .{ .checkpoint_every = asked.checkpoint_every, .ram_budget = asked.ram_budget, .frame_hz = asked.frame_hz }
    else
        null;
    setup.open(allocator, io, asked.elf, null, history_opts) catch |err| {
        std.debug.print("serve: cannot open {s}: {s}\n", .{ asked.elf, @errorName(err) });
        return 1;
    };
    defer setup.deinit();
    if (asked.usbip) |port| {
        usbip_run.install(&setup.owner.board().usb, bridges.allocator(), io, port) catch |err| {
            std.debug.print("serve: cannot export the FS device: {s}\n", .{@errorName(err)});
            return 1;
        };
        setup.attachUsbip() catch |err| {
            std.debug.print("serve: cannot record the USB/IP bridge: {s}\n", .{@errorName(err)});
            return 1;
        };
    }
    card_setup.prepareSdhi(setup.owner.board(), io, asked.sdhi) catch |err| {
        std.debug.print("serve: cannot fill the SD card: {s}\n", .{@errorName(err)});
        return 1;
    };
    var staged: [card_apps.max_apps]card_apps.Staged = undefined;
    const apps = card_apps.paired(io, allocator, asked.sdhi.appPaths(), &staged) catch |err| {
        std.debug.print("serve: cannot read a module ELF: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer card_apps.unload(allocator, apps);
    var pairs: [card_apps.max_apps]txm_debug.Pair = undefined;
    setup.pairModules(card_apps.pairs(apps, &pairs) catch |err| {
        std.debug.print("serve: a module ELF is not an ELF: {s}\n", .{@errorName(err)});
        return 1;
    });
    var armer = BreakArmer{ .session = setup.context.session };
    if (setup.context.modules) |table|
        table.armer = .{ .ctx = &armer, .arm = BreakArmer.arm, .drop = BreakArmer.drop };
    if (asked.cpu1) |path| setup.openSecond(path) catch |err| {
        std.debug.print("serve: cannot bring up CPU1 from {s}: {s}\n", .{ path, @errorName(err) });
        return 1;
    };
    if (asked.folded) setup.sampleStacks(fold_every) catch |err| {
        std.debug.print("serve: cannot sample stacks: {s}\n", .{@errorName(err)});
        return 1;
    };
    // Snapshot and restore stay off a non-loopback TCP listener unless the
    // operator asked for them there (RA8EMU-1175): a network peer could
    // otherwise overwrite or read files as the serving user.
    switch (asked.where) {
        .listen => |spec| if (!listen.allowsState(spec, asked.allow_state_files)) {
            setup.context.state = null;
            std.debug.print("serve: snapshot and restore are off on a non-loopback listener; pass --allow-state-files to keep them\n", .{});
        },
        .stdio => {},
    }
    const buffers: loop.Buffers = .{ .rx = setup.rx, .tx = setup.tx };
    const context = &setup.context;
    const done = switch (asked.where) {
        .stdio => loop.answerStdio(io, context, buffers),
        .listen => |spec| listen.serve(io, spec, context, buffers),
    };
    done catch |err| {
        std.debug.print("serve: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}
