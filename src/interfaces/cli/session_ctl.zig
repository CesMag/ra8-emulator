//! `ra8_emulator ctl --connect unix:PATH|tcp:HOST:PORT [--json] COMMAND`
//! (RA8EMU-747): one command against a running `serve`, one connection per
//! command. serve keeps the session between clients, so a script of ctl
//! calls drives one continuous machine.
//!
//! `ctl --host NAME --image ELF` (RA8EMU-196) instead starts a `serve
//! --stdio` on the profile's host for this one command, so each call is a
//! fresh machine booted from ELF.
const std = @import("std");
const proto = @import("ra8_rpc").session_rpc;
const Spec = @import("serve_listen.zig").Spec;
const ctl_client = @import("ctl_client.zig");
const Client = ctl_client.Client;
const profiles = @import("ra8_host").profiles;
const host_spawn = @import("host_spawn.zig");
const out = @import("ctl_print.zig");
pub const events = @import("ctl_events.zig");

pub const usage =
    \\usage: ra8_emulator ctl --connect unix:PATH|tcp:[HOST]:PORT [--json] COMMAND
    \\       ra8_emulator ctl --host NAME [--hosts FILE] --image ELF [--json] COMMAND
    \\  commands: load ELF | run [--budget N] | step | pause | regs [NAME...] | mem ADDRESS LENGTH
    \\            speed FACTOR|max | break ADDRESS | break --clear ID
    \\            watch ADDRESS read|write|access | watch --clear ID
    \\            events [--topic uart|stop]... [--until TEXT] [--timeout 500ms|30s]
    \\            advance 500ms|600s
    \\            plug MODEL@ENDPOINT | unplug ENDPOINT
    \\            snapshot PATH | restore PATH (paths on the serving host)
    \\            map (the memory map of the image last loaded)
    \\            stack (MSP and PSP, the lowest each reached, any overflow)
    \\            rtc (the board's RTC date and time)
    \\            periph [BLOCK] (the peripheral blocks, or one block's registers)
    \\            folded [THREAD] [FROM_NS TO_NS] (sampled stacks; serve --profile-folded)
    \\            fault MODEL@ENDPOINT=MODE | fault --clear ENDPOINT
    \\
;

/// What `regs` reads when it is given no names.
const default_regs = [_]proto.Register{ .r0, .r1, .r2, .r3, .r4, .r5, .r6, .r7, .r8, .r9, .r10, .r11, .r12, .sp, .lr, .pc, .xpsr };
const max_regs = 32;

pub const Command = union(enum) {
    load: []const u8,
    run: u64,
    /// Virtual nanoseconds of board time to run through (RA8EMU-654).
    advance: u64,
    step,
    pause,
    regs: []const proto.Register,
    mem: struct { address: u32, length: u32 },
    /// Thousandths of the default rate; zero is `max`.
    speed: u64,
    set_break: u32,
    clear_break: u32,
    set_watch: struct { address: u32, access: proto.Access },
    clear_watch: u32,
    events: events.Options,
    /// A part spec in `--attach`/`--fault` syntax, parsed by the server.
    part: Part,
    /// A run file on the serving host (RA8EMU-768).
    files: Files,
    /// The memory map of the last loaded image (RA8EMU-794).
    map,
    /// The stack pointers, their low marks and any overflow (RA8EMU-816).
    stack,
    /// The board's RTC calendar (RA8EMU-809).
    rtc,
    /// The peripheral blocks, or one block's registers when named (RA8EMU-818).
    periph: []const u8,
    /// CPU0's sampled stacks, folded, for one thread and window (RA8EMU-833).
    folded: Folded,
};

/// What `ctl folded` asks for; the defaults take every thread, all time.
pub const Folded = struct { thread: u32 = proto.all_threads, from_ns: u64 = 0, to_ns: u64 = 0xFFFF_FFFF_FFFF_FFFF };

pub const Part = struct { method: proto.Method, text: []const u8 };

pub const Files = struct { method: proto.Method, path: []const u8 };

/// A profile from the hosts file and the image its `serve` boots.
pub const Host = struct { name: []const u8, hosts: ?[]const u8, image: []const u8 };

pub const Where = union(enum) { connect: Spec, host: Host };

pub const Request = struct { where: Where, json: bool, command: Command };

/// Parse `argv`; `--json`, `--hosts` and `--image` may sit anywhere after
/// the connect spec or host name.
pub fn parse(allocator: std.mem.Allocator, argv: []const []const u8) !Request {
    if (argv.len < 5 or !std.mem.eql(u8, argv[1], "ctl")) return error.BadArguments;
    const by_host = std.mem.eql(u8, argv[2], "--host");
    if (!by_host and !std.mem.eql(u8, argv[2], "--connect")) return error.BadArguments;
    var words: std.ArrayList([]const u8) = .empty;
    var json = false;
    var hosts: ?[]const u8 = null;
    var image: ?[]const u8 = null;
    var index: usize = 4;
    while (index < argv.len) : (index += 1) {
        const word = argv[index];
        if (std.mem.eql(u8, word, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, word, "--hosts") or std.mem.eql(u8, word, "--image")) {
            index += 1;
            if (index == argv.len) return error.BadArguments;
            if (word[2] == 'h') hosts = argv[index] else image = argv[index];
        } else try words.append(allocator, word);
    }
    if (words.items.len == 0) return error.BadArguments;
    const command = try parseCommand(allocator, words.items[0], words.items[1..]);
    if (!by_host) {
        if (hosts != null or image != null) return error.BadArguments;
        return .{ .where = .{ .connect = try Spec.parse(argv[3]) }, .json = json, .command = command };
    }
    const host: Host = .{ .name = argv[3], .hosts = hosts, .image = image orelse return error.MissingImage };
    return .{ .where = .{ .host = host }, .json = json, .command = command };
}

/// The link `where` names: a socket, or a `serve --stdio` started for it.
fn target(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, where: Where) !ctl_client.Target {
    switch (where) {
        .connect => |spec| return .{ .socket = spec },
        .host => |host| {
            const profile = try profiles.load(allocator, io, env, host.hosts, host.name);
            return .{ .spawn = try host_spawn.serveArgv(allocator, io, profile, host.image) };
        },
    }
}

fn parseCommand(allocator: std.mem.Allocator, name: []const u8, args: []const []const u8) !Command {
    const eql = std.mem.eql;
    if (eql(u8, name, "load")) return if (args.len == 1) .{ .load = args[0] } else error.BadArguments;
    if (eql(u8, name, "run")) return .{ .run = try parseBudget(args) };
    if (eql(u8, name, "advance")) return if (args.len == 1) .{ .advance = try parseAdvance(args[0]) } else error.BadArguments;
    if (eql(u8, name, "step")) return if (args.len == 0) .step else error.BadArguments;
    if (eql(u8, name, "pause")) return if (args.len == 0) .pause else error.BadArguments;
    if (eql(u8, name, "map")) return if (args.len == 0) .map else error.BadArguments;
    if (eql(u8, name, "stack")) return if (args.len == 0) .stack else error.BadArguments;
    if (eql(u8, name, "rtc")) return if (args.len == 0) .rtc else error.BadArguments;
    if (eql(u8, name, "folded")) return .{ .folded = try parseFolded(args) };
    if (eql(u8, name, "periph")) return if (args.len <= 1) .{ .periph = if (args.len == 1) args[0] else "" } else error.BadArguments;
    if (eql(u8, name, "regs")) return .{ .regs = try parseRegs(allocator, args) };
    if (eql(u8, name, "speed")) return if (args.len == 1) .{ .speed = try parseSpeed(args[0]) } else error.BadArguments;
    if (eql(u8, name, "break")) return parseBreak(args);
    if (eql(u8, name, "watch")) return parseWatch(args);
    if (eql(u8, name, "events")) return .{ .events = try events.parse(args) };
    if (eql(u8, name, "plug")) return part(.plug, args);
    if (eql(u8, name, "unplug")) return part(.unplug, args);
    if (eql(u8, name, "fault")) return parseFault(args);
    if (eql(u8, name, "snapshot")) return if (args.len == 1) .{ .files = .{ .method = .snapshot, .path = args[0] } } else error.BadArguments;
    if (eql(u8, name, "restore")) return if (args.len == 1) .{ .files = .{ .method = .restore, .path = args[0] } } else error.BadArguments;
    if (!eql(u8, name, "mem")) return error.UnknownCommand;
    if (args.len != 2) return error.BadArguments;
    const length = try std.fmt.parseInt(u32, args[1], 0);
    if (length == 0) return error.BadLength;
    return .{ .mem = .{ .address = try std.fmt.parseInt(u32, args[0], 0), .length = length } };
}

/// A duration in `events --timeout` syntax, as virtual nanoseconds.
/// `folded`, `folded THREAD`, `folded FROM TO` or `folded THREAD FROM TO`.
fn parseFolded(args: []const []const u8) !Folded {
    var asked: Folded = .{};
    const window = switch (args.len) {
        0 => return asked,
        1 => return .{ .thread = try std.fmt.parseInt(u32, args[0], 0) },
        2 => args,
        3 => args[1..],
        else => return error.BadArguments,
    };
    if (args.len == 3) asked.thread = try std.fmt.parseInt(u32, args[0], 0);
    asked.from_ns = try std.fmt.parseInt(u64, window[0], 0);
    asked.to_ns = try std.fmt.parseInt(u64, window[1], 0);
    return asked;
}

fn parseAdvance(word: []const u8) !u64 {
    const ms: u64 = @intCast(try events.parseDuration(word));
    return ms * std.time.ns_per_ms;
}

fn parseBudget(args: []const []const u8) !u64 {
    if (args.len == 0) return 0;
    if (args.len == 2 and std.mem.eql(u8, args[0], "--budget")) return std.fmt.parseInt(u64, args[1], 0);
    return error.BadArguments;
}

/// `max`, or a positive factor of the default rate kept to thousandths.
fn parseSpeed(word: []const u8) !u64 {
    if (std.mem.eql(u8, word, "max")) return 0;
    const factor = try std.fmt.parseFloat(f64, word);
    if (!std.math.isFinite(factor) or factor < 0.001 or factor > 1e9) return error.BadSpeed;
    return @intFromFloat(@round(factor * 1000.0));
}

fn parseBreak(args: []const []const u8) !Command {
    if (args.len == 1) return .{ .set_break = try std.fmt.parseInt(u32, args[0], 0) };
    if (args.len == 2 and std.mem.eql(u8, args[0], "--clear")) return .{ .clear_break = try std.fmt.parseInt(u32, args[1], 0) };
    return error.BadArguments;
}

fn parseWatch(args: []const []const u8) !Command {
    if (args.len != 2) return error.BadArguments;
    if (std.mem.eql(u8, args[0], "--clear")) return .{ .clear_watch = try std.fmt.parseInt(u32, args[1], 0) };
    const access = std.meta.stringToEnum(proto.Access, args[1]) orelse return error.UnknownAccess;
    return .{ .set_watch = .{ .address = try std.fmt.parseInt(u32, args[0], 0), .access = access } };
}

fn part(method: proto.Method, args: []const []const u8) !Command {
    if (args.len != 1) return error.BadArguments;
    return .{ .part = .{ .method = method, .text = args[0] } };
}

fn parseFault(args: []const []const u8) !Command {
    if (args.len == 2 and std.mem.eql(u8, args[0], "--clear")) return part(.clear_fault, args[1..]);
    return part(.set_fault, args);
}

fn parseRegs(allocator: std.mem.Allocator, names: []const []const u8) ![]const proto.Register {
    if (names.len == 0) return &default_regs;
    if (names.len > max_regs) return error.TooManyRegisters;
    const regs = try allocator.alloc(proto.Register, names.len);
    for (names, regs) |name, *reg| reg.* = std.meta.stringToEnum(proto.Register, name) orelse return error.UnknownRegister;
    return regs;
}

/// Run `argv` (`ra8_emulator ctl --connect|--host ...`) and return the exit code.
pub fn run(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, argv: []const []const u8) !u8 {
    const request = parse(allocator, argv) catch |err| {
        std.debug.print("ctl: {s}\n{s}", .{ @errorName(err), usage });
        return 2;
    };
    const reach = target(allocator, io, env, request.where) catch |err| return out.failed(io, request.json, err, 0);
    const client = Client.open(allocator, io, reach) catch |err| return out.failed(io, request.json, err, 0);
    defer client.close();
    return perform(allocator, io, client, request) catch |err| return out.failed(io, request.json, err, client.refused);
}

fn perform(allocator: std.mem.Allocator, io: std.Io, client: *Client, request: Request) !u8 {
    var stdout = std.Io.File.stdout().writerStreaming(io, &.{});
    const w = &stdout.interface;
    const json = request.json;
    switch (request.command) {
        .events => |options| return events.watch(client, w, json, options),
        .load => |path| {
            const image = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(proto.max_payload));
            _ = try client.call(proto.Ack, proto.Load, .load, .{ .core = .cpu0, .image = image });
            try out.loaded(w, json, path, image.len);
        },
        .run => |budget| try runTo(client, w, json, budget),
        .advance => |ns| {
            const moved = try client.call(proto.Advanced, proto.Advance, .advance, .{ .core = .cpu0, .ns = ns });
            try out.advanced(w, json, moved);
        },
        .step => try runTo(client, w, json, null),
        .pause => {
            _ = try client.call(proto.Ack, proto.CoreOnly, .pause, .{ .core = .cpu0 });
            try out.paused(w, json);
        },
        .regs => |regs| {
            var values: [max_regs]out.Reg = undefined;
            for (regs, values[0..regs.len]) |reg, *value| {
                const read = try client.call(proto.U32, proto.ReadRegister, .read_register, .{ .core = .cpu0, .register = reg });
                value.* = .{ .register = reg, .value = read.value };
            }
            try out.registers(w, json, values[0..regs.len]);
        },
        .mem => |at| {
            const args: proto.ReadMemory = .{ .core = .cpu0, .address = at.address, .length = at.length };
            const memory = try client.call(proto.Memory, proto.ReadMemory, .read_memory, args);
            try out.memory(w, json, at.address, memory.bytes);
        },
        .speed => |milli| {
            _ = try client.call(proto.Ack, proto.SetSpeed, .set_speed, .{ .core = .cpu0, .milli = milli });
            try out.speed(w, json, milli);
        },
        .set_break => |address| {
            const id = try client.call(proto.U32, proto.Point, .set_breakpoint, .{ .core = .cpu0, .address = address });
            try out.point(w, json, "breakpoint", id.value, address, null);
        },
        .set_watch => |at| {
            const last = std.math.add(u32, at.address, watch_bytes - 1) catch return error.BadAddress;
            const args: proto.Watch = .{ .core = .cpu0, .first = at.address, .last = last, .access = at.access };
            const id = try client.call(proto.U32, proto.Watch, .set_watchpoint, args);
            try out.point(w, json, "watchpoint", id.value, at.address, at.access);
        },
        .clear_break => |id| try clear(client, w, json, .clear_breakpoint, id),
        .clear_watch => |id| try clear(client, w, json, .clear_watchpoint, id),
        .part => |asked| {
            _ = try client.call(proto.Ack, proto.PartSpec, asked.method, .{ .core = .cpu0, .text = asked.text });
            try out.part(w, json, asked.method, asked.text);
        },
        .files => |asked| {
            _ = try client.call(proto.Ack, proto.StatePath, asked.method, .{ .path = asked.path });
            try out.files(w, json, asked.method, asked.path);
        },
        .map => {
            const map = try client.call(proto.MapText, proto.MapAsk, .map, .{ .core = .cpu0, .json = @intFromBool(json) });
            try out.map(w, json, map.text);
        },
        .periph => |block| {
            const listed = try client.call(proto.PeriphText, proto.PeriphAsk, .periph, .{ .core = .cpu0, .json = @intFromBool(json), .block = block });
            try out.periph(w, json, listed.text);
        },
        .folded => |asked| try foldedRows(client, w, json, asked),
        .stack => {
            const report = try client.call(proto.StackReport, proto.CoreOnly, .stack, .{ .core = .cpu0 });
            try out.stack(w, json, report);
        },
        .rtc => {
            const report = try client.call(proto.RtcReport, proto.CoreOnly, .rtc, .{ .core = .cpu0 });
            try out.rtc(w, json, report);
        },
    }
    return 0;
}

/// Bytes a `watch` covers from its address, the same span the debugger's
/// own watch command uses.
const watch_bytes = 4;

/// CPU0's sampled stacks folded for one thread and window (RA8EMU-833).
fn foldedRows(client: *Client, w: anytype, json: bool, asked: Folded) !void {
    const ask: proto.FoldedAsk = .{ .core = .cpu0, .thread = asked.thread, .from_ns = asked.from_ns, .to_ns = asked.to_ns };
    const rows = try client.call(proto.FoldedText, proto.FoldedAsk, .folded, ask);
    try out.folded(w, json, rows.text);
}

fn clear(client: *Client, w: anytype, json: bool, method: proto.Method, id: u32) !void {
    _ = try client.call(proto.Ack, proto.PointId, method, .{ .core = .cpu0, .id = id });
    try out.cleared(w, json, id);
}

/// Run with `budget` (or one step when null) and print the stop it ends in.
fn runTo(client: *Client, w: anytype, json: bool, budget: ?u64) !void {
    _ = try client.call(proto.Ack, proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .stop });
    if (budget) |instructions| {
        _ = try client.call(proto.Ack, proto.Run, .run, .{ .core = .cpu0, .mode = .cont, .budget = instructions });
    } else {
        _ = try client.call(proto.Ack, proto.CoreOnly, .step, .{ .core = .cpu0 });
    }
    try out.stopped(w, json, try client.stop());
}
