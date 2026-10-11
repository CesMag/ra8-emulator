//! ra8_gui's command line and its one window (RA8EMU-770, RA8EMU-1097): the
//! docked debugger shell on an image, `ra8_gui [flags] IMAGE`. It picks the
//! host (the local one unless --host names a profile in the hosts file),
//! serves the local session in-process (local_session.zig), loads the image
//! once the session greets, and runs the shell loop (RA8EMU-763) until the
//! window closes, one frame every sixtieth of a second. The image stays
//! halted at reset until Run is pressed on the time bar (RA8EMU-1118).
//! Only the local host connects so far; SSH profiles join with RA8EMU-761.
const std = @import("std");
const host_profiles = @import("ra8_host").profiles;
const platform = @import("platform.zig");
const pane_layout = @import("ui/pane_layout.zig");
const shell_loop = @import("shell_loop.zig");
const shell_panes = @import("shell_panes.zig");
const shell_console = @import("shell_console.zig");
const shell_board = @import("shell_board.zig");
const shell_board_input = @import("shell_board_input.zig");
const shell_devices = @import("shell_devices.zig");
const shell_fault = @import("shell_fault.zig");
const shell_camera = @import("shell_camera.zig");
const shell_plug = @import("shell_plug.zig");
const shell_camera_file = @import("shell_camera_file.zig");
const shell_startup = @import("shell_startup.zig");
const window_stills = @import("window_stills.zig");
const source_spec = @import("ra8_host").camera.source_spec;
const shell_registers = @import("shell_registers.zig");
const shell_stack = @import("shell_stack.zig");
const shell_memory = @import("shell_memory.zig");
const session_link = @import("session_link.zig");
const local_session = @import("local_session.zig");
const shell_run = @import("shell_run.zig");
const shell_time = @import("shell_time.zig");
const wall_clock = @import("wall_clock.zig");
const proto = @import("ra8_rpc").session_rpc;
const colors = @import("ui/colors.zig");

const Env = proto.Client.Env;
const usage = "usage: ra8_gui [--host NAME] [--hosts FILE] [--attach MODEL@ENDPOINT]... [--click]\n" ++
    "    [--camera-source KIND[:ARG]] [--window-stills DIR [--window-stills-every N]]\n" ++
    "    [--frames N] [--theme dark|light] IMAGE\n";

/// The word `ra8_gui shell IMAGE` carried while ra8_gui also had a live
/// window; still taken in front of the flags, and it changes nothing.
const shell_word = "shell";

/// Largest image the shell reads, as main does for a run.
const max_image: usize = 64 * 1024 * 1024;

/// The window's frame: a lit run owes the board this much of its own time
/// each one (shell_run.zig), so the loop holds to it.
const frame_ns: u64 = shell_run.frame_ns;

pub const Args = struct {
    image: []const u8,
    host: ?[]const u8 = null,
    hosts: ?[]const u8 = null,
    /// The `--attach` and `--click` plugs (RA8EMU-1095).
    startup: shell_startup.Startup = .{},
    /// `--camera-source`: the camera panel starts on this source.
    camera: ?source_spec.Spec = null,
    /// `--window-stills DIR` keeps every `stills_every`-th frame as a PNG.
    stills: ?[]const u8 = null,
    stills_every: u32 = 1,
    /// `--frames N`: close the window after N frames drawn with the image
    /// loaded, for a smoke run with nobody to close it (RA8EMU-1089).
    frames: ?u32 = null,
    /// `--theme dark|light`: the palette the window paints with (RA8EMU-961).
    theme: colors.Choice = .dark,
};

/// Parse `ra8_gui [flags] IMAGE`; see `usage`.
pub fn parse(argv: []const []const u8) error{Usage}!Args {
    if (argv.len < 2) return error.Usage;
    var args: Args = .{ .image = "" };
    var image: ?[]const u8 = null;
    var i: usize = if (std.mem.eql(u8, argv[1], shell_word)) 2 else 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--click")) {
            args.startup.addClick() catch return error.Usage;
        } else if (valued(arg)) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            take(&args, arg, argv[i]) catch return error.Usage;
        } else if (std.mem.startsWith(u8, arg, "-") or image != null) {
            return error.Usage;
        } else image = arg;
    }
    args.image = image orelse return error.Usage;
    return args;
}

const valued_flags = [_][]const u8{ "--host", "--hosts", "--attach", "--camera-source", "--window-stills", "--window-stills-every", "--frames", "--theme" };

fn valued(arg: []const u8) bool {
    for (valued_flags) |flag| if (std.mem.eql(u8, arg, flag)) return true;
    return false;
}

/// Set the flag `flag` from its value.
fn take(args: *Args, flag: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, flag, "--host")) {
        args.host = value;
    } else if (std.mem.eql(u8, flag, "--hosts")) {
        args.hosts = value;
    } else if (std.mem.eql(u8, flag, "--attach")) {
        try args.startup.add(value);
    } else if (std.mem.eql(u8, flag, "--camera-source")) {
        args.camera = try source_spec.parse(value);
    } else if (std.mem.eql(u8, flag, "--window-stills")) {
        args.stills = value;
    } else if (std.mem.eql(u8, flag, "--window-stills-every")) {
        args.stills_every = try count(value);
    } else if (std.mem.eql(u8, flag, "--theme")) {
        args.theme = std.meta.stringToEnum(colors.Choice, value) orelse return error.BadValue;
    } else {
        args.frames = try count(value);
    }
}

/// A count on the command line: a decimal above zero.
fn count(text: []const u8) !u32 {
    const value = try std.fmt.parseInt(u32, text, 10);
    if (value == 0) return error.BadValue;
    return value;
}

/// The host the shell connects to: the local one unless --host names a
/// profile, which comes from the hosts file. "local" needs no file.
pub fn pick(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, args: Args) !host_profiles.Profile {
    const name = args.host orelse return .local;
    if (std.mem.eql(u8, name, "local")) return .local;
    return host_profiles.load(allocator, io, env, args.hosts, name);
}

/// Run the shell in the window `opener` opens; 2 when the command line,
/// host, or window is unusable. `allocator` is main's arena.
pub fn run(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, argv: []const []const u8, opener: platform.Opener) !u8 {
    const args = parse(argv) catch {
        std.debug.print(usage, .{});
        return 2;
    };
    const profile = pick(allocator, io, env, args) catch |err| {
        std.debug.print("no host {s}: {s}\n", .{ args.host.?, @errorName(err) });
        return 2;
    };
    if (profile == .ssh) {
        std.debug.print("the shell connects to the local host only so far; ctl --host reaches ssh hosts\n", .{});
        return 2;
    }
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, args.image, allocator, .limited(max_image)) catch |err| {
        std.debug.print("cannot read {s}: {s}\n", .{ args.image, @errorName(err) });
        return 1;
    };
    const window = opener.open() orelse {
        std.debug.print("ra8_gui could not open a window\n", .{});
        return 2;
    };
    defer opener.close();
    const stills_dir = try window_stills.openDir(io, args.stills);
    defer if (stills_dir) |dir| dir.close(io);
    var recorder = window_stills.Recorder{ .allocator = allocator, .inner = window, .io = io, .dir = stills_dir orelse std.Io.Dir.cwd(), .stem = "window", .every = args.stills_every };
    const shown = if (stills_dir != null) recorder.platform() else window;
    var startup = args.startup;
    local(allocator, io, shown, args, &startup, bytes) catch |err| switch (err) {
        error.ImageNotLoaded => {
            std.debug.print("ra8_gui: the session did not load {s}\n", .{args.image});
            return 1;
        },
        else => return err,
    };
    return 0;
}

/// Serve the image in-process and run the shell on it.
fn local(allocator: std.mem.Allocator, io: std.Io, window: platform.Platform, args: Args, startup: *shell_startup.Startup, bytes: []const u8) !void {
    const path = args.image;
    var session: local_session.LocalSession = undefined;
    try session.open(allocator, io, path);
    defer session.deinit();
    const rx = try allocator.alloc(u8, 2 * Env.max_frame);
    const tx = try allocator.alloc(u8, Env.max_frame);
    var link: session_link.Link = undefined;
    link.open(session.transport(), rx, tx);
    var shell = shell_loop.Shell.init(allocator, try pane_layout.twoCore(allocator));
    shell.theme = colors.of(args.theme);
    defer shell.deinit();
    shell.link = &link;
    shell.server = served(&session);
    var host_clock = wall_clock.Host.init(io);
    shell.clock = host_clock.clock();
    var time: shell_time.Time = .{};
    shell.time = &time;
    var console = shell_console.Console.init(allocator);
    defer console.deinit();
    shell.console = &console;
    var board = shell_board.Board.init(allocator);
    defer board.deinit();
    shell.board = &board;
    var board_input: shell_board_input.Pointer = .{};
    shell.board_input = &board_input;
    var devices: shell_devices.Devices = .{};
    shell.devices = &devices;
    var faults: shell_fault.Faults = .{};
    shell.faults = &faults;
    var camera: shell_camera.Camera = .{};
    // The project is the directory ra8_gui was started in (RA8EMU-1124).
    camera.kept = .begin(io, std.Io.Dir.cwd(), &camera.panel);
    if (args.camera) |spec| shell_camera.start(&camera, spec);
    shell.camera = &camera;
    shell.startup = startup;
    var plug: shell_plug.Plug = .{};
    try plug.init();
    shell.plug = &plug;
    var camera_file: shell_camera_file.CameraFile = .{};
    try camera_file.init();
    shell.camera_file = &camera_file;
    var registers: shell_registers.Pair = .{};
    shell.registers = &registers;
    var stack: shell_stack.Pair = .{};
    shell.stack = &stack;
    var memory: shell_memory.Pair = .{};
    shell.memory = &memory;
    var code: shell_memory.Pair = .{ .follows = .pc };
    shell.code = &code;
    var panes: shell_panes.Panes = .{ .console = &console, .board = &board, .board_input = &board_input, .devices = &devices, .faults = &faults, .camera = &camera, .plug = &plug, .camera_file = &camera_file, .registers = &registers, .memory = &memory, .code = &code, .stack = &stack };
    shell.painter = panes.painter();
    try drive(io, &shell, window, path, bytes, args.frames);
    link.close();
}

/// `session` as the shell answers it: in this process, on the shell's thread.
pub fn served(session: *local_session.LocalSession) shell_loop.Server {
    return .{ .context = session, .answerFn = answerLocal };
}

fn answerLocal(context: *anyopaque) anyerror!void {
    const session: *local_session.LocalSession = @ptrCast(@alignCast(context));
    return session.answer();
}

/// Step `shell` once a frame until its window closes, loading the image once
/// its session has greeted. With `frames` it also ends after that many
/// frames drawn with the image loaded, and fails once the image can no
/// longer load, so a run with nobody at the window always ends.
pub fn drive(io: std.Io, shell: *shell_loop.Shell, window: platform.Platform, path: []const u8, bytes: []const u8, frames: ?u32) !void {
    var sent = false;
    var drawn: u32 = 0;
    var pace = wall_clock.Host.init(io);
    const clock = pace.clock();
    while (true) {
        const began = clock.now();
        if (!try shell.step(window)) return;
        if (!sent and shell.state() == .connected) {
            const link = shell.link orelse return;
            try shell.status.load(link, path, bytes);
            sent = true;
        }
        if (frames) |wanted| {
            if (lost(shell)) return error.ImageNotLoaded;
            if (shell.status.image != null) drawn += 1;
            if (drawn == wanted) return;
        }
        // The rest of the frame; a frame that ran over starts the next at once.
        const spent = clock.now() - began;
        if (spent < frame_ns) try io.sleep(.fromNanoseconds(frame_ns - spent), .awake);
    }
}

/// Whether the image can no longer load: the session is gone or refused it.
fn lost(shell: *const shell_loop.Shell) bool {
    return switch (shell.state()) {
        .failed, .closed => true,
        .connecting, .connected => shell.status.refused == .load,
    };
}
