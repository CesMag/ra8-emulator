//! ra8_gui: the debugger GUI (RA8EMU-202).
//!
//! Run with an image to debug, or with none and open one from File > Open
//! ELF (Cmd+O), a drop or the recents:
//!
//!   ra8_gui path/to/firmware.elf
//!   ra8_gui
//!   ra8_gui --headless --gui-script test_run.txt --gui-video-out out.mp4 firmware.elf
//!
//! Opens an SDL window, serves the image on a local session (boot.zig)
//! and draws the debugger shell (shell/loop.zig).
const std = @import("std");
const proto = @import("ra8_rpc").session.rpc;
const wall_clock = @import("../wall_clock.zig");
const render_driver = @import("../render_driver.zig");
const pane_layout = @import("../ui/pane_layout.zig");
const window_stills = @import("../window/stills.zig");
const platform = @import("../platform.zig");
const headless_mod = @import("../headless.zig");
const chunked = @import("ra8_rpc").session.load_chunks;
const shell_loop = @import("loop.zig");
const shell_window = @import("window_store.zig");
const shell_settings = @import("settings_page.zig");
const shell_layout = @import("layout_store.zig");
const shell_time = @import("time.zig");
const shell_console = @import("console.zig");
const shell_board = @import("board/board.zig");
const shell_board_store = @import("board_store.zig");
const shell_board_input = @import("board/input.zig");
const shell_devices = @import("devices.zig");
const shell_fault = @import("fault.zig");
const shell_camera = @import("camera/camera.zig");
const shell_camera_file = @import("camera/file.zig");
const shell_startup = @import("startup.zig");
const shell_plug = @import("plug.zig");
const shell_registers = @import("registers.zig");
const shell_register_edit = @import("register_edit.zig");
const shell_stack = @import("stack.zig");
const shell_source = @import("source.zig");
const shell_locals = @import("locals.zig");
const shell_memory = @import("memory.zig");
const shell_map = @import("map.zig");
const shell_branches = @import("branch_state.zig");
const shell_diff = @import("diff_state.zig");
const shell_filmstrip = @import("filmstrip_feed.zig");
const shell_memory_field = @import("memory_field.zig");
const shell_breaks = @import("breaks.zig");
const shell_open = @import("open.zig");
const shell_panes = @import("panes.zig");
const shell_recents = @import("recents.zig");
const shell_recent_menu = @import("recent_menu.zig");
const shell_board_pick = @import("board_pick.zig");
const shell_board_profiles = @import("board_profiles.zig");
const shell_run = @import("run.zig");
const shell_pace = @import("pace.zig");
const speed_field = @import("../speed_field.zig");
const host_profiles = @import("ra8_host").profiles;
const host_listener = @import("ra8_rpc").host_listener;
const script_mod = @import("../script/script.zig");
const video_mod = @import("../video/video.zig");
const args_mod = @import("args.zig");
const first_image = @import("first_image.zig");
const shell_boot = @import("boot.zig");

pub const Args = args_mod.Args;
pub const Limits = args_mod.Limits;
pub const parse = args_mod.parse;
pub const pick = args_mod.pick;
pub const usage = args_mod.usage;

const Env = proto.Client.Env;

const WindowBackend = struct {
    platform: platform.Platform,
    headless: ?*headless_mod.Headless = null,
    allocator: std.mem.Allocator,
    opened: bool = false,

    fn deinit(self: *WindowBackend, opener: platform.Opener) void {
        if (self.headless) |h| {
            h.deinit();
            self.allocator.destroy(h);
        }
        if (self.opened) opener.close();
    }
};

fn initWindow(allocator: std.mem.Allocator, opener: platform.Opener, args: Args, geom: ?platform.WindowState) !WindowBackend {
    const default_w = if (geom) |g| @max(g.width, 800) else 1024;
    const default_h = if (geom) |g| @max(g.height, 500) else 768;
    if (args.headless) {
        const h = try allocator.create(headless_mod.Headless);
        h.* = headless_mod.Headless.init(allocator, default_w, default_h);
        return .{ .platform = h.platform(), .headless = h, .allocator = allocator };
    }
    if (opener.open(geom)) |w| {
        return .{ .platform = w, .opened = true, .allocator = allocator };
    }
    std.debug.print("ra8_gui could not open a window\n", .{});
    return error.NoWindow;
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, argv: []const []const u8, opener: platform.Opener, prefs: ?[]const u8) !u8 {
    const args = parse(argv) catch {
        std.debug.print("{s}", .{usage});
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
    if (host_listener.focusRunning(allocator, io, env)) |_| {
        std.debug.print("ra8_gui: focused the running emulator\n", .{});
        return 0;
    } else |_| {}
    const named: ?first_image.Image = if (args.image) |path| first_image.read(allocator, io, path) orelse return 1 else null;
    render_driver.override = args.render_driver;

    var window_store = shell_window.Store{ .io = io, .allocator = allocator, .dir = prefs };
    var backend = initWindow(allocator, opener, args, window_store.restore()) catch return 2;
    defer backend.deinit(opener);

    var script_runner: ?script_mod.runner.Runner = null;
    var script_obj: ?script_mod.parser.Script = null;
    defer if (script_obj) |*s| s.deinit();
    defer if (script_runner) |*r| r.deinit();
    if (args.gui_script) |p| {
        const text = std.Io.Dir.cwd().readFileAlloc(io, p, allocator, .limited(1024 * 1024)) catch return 1;
        script_obj = script_mod.parser.parse(allocator, text) catch return 1;
        script_runner = script_mod.runner.Runner.init(allocator, script_obj.?.items.items, args.headless);
    }

    var video_writer: ?video_mod.writer.Writer = null;
    defer if (video_writer) |*w| w.deinit();
    defer if (video_writer) |*w| w.finish() catch {};
    if (args.gui_video_out) |p| video_writer = video_mod.writer.Writer.init(allocator, io, p, args.gui_video_fps) catch return 1;

    const stills_dir = try window_stills.openDir(io, args.stills);
    defer if (stills_dir) |dir| dir.close(io);
    var recorder = window_stills.Recorder{ .allocator = allocator, .inner = backend.platform, .io = io, .dir = stills_dir orelse std.Io.Dir.cwd(), .stem = "window", .every = args.stills_every };
    const inner_platform = if (stills_dir != null) recorder.platform() else backend.platform;

    var cap = video_mod.capture.Capture.init(allocator, inner_platform);
    defer cap.deinit();
    if (script_runner) |*r| cap.runner = r;
    if (video_writer) |*w| cap.writer = w;
    cap.fps = args.gui_video_fps;
    cap.show_cursor = args.show_cursor;

    var startup = args.startup;
    const shown = if (named) |image| image.path else "the image";
    local(allocator, io, env, cap.platform(), &cap, args, &startup, named, prefs) catch |err| switch (err) {
        error.ImageNotLoaded => {
            std.debug.print("ra8_gui: the session did not load {s}\n", .{shown});
            return 1;
        },
        error.Oversize => {
            std.debug.print("ra8_gui: {s} is larger than the {d} bytes a session takes\n", .{ shown, chunked.max_image });
            return 1;
        },
        else => return err,
    };
    window_store.save(shell_window.capture(backend.platform));
    return 0;
}

const ShellFeeds = struct {
    board_input: shell_board_input.Pointer = .{},
    devices: shell_devices.Devices = .{},
    faults: shell_fault.Faults = .{},
    camera: shell_camera.Camera = .{},
    plug: shell_plug.Plug = .{},
    camera_file: shell_camera_file.CameraFile = .{},
    registers: shell_registers.Pair = .{},
    edit: shell_register_edit.Editor = .{},
    stack: shell_stack.Pair = .{},
    locals: shell_locals.Pair = .{},
    memory: shell_memory.Pair = .{},
    memory_field: shell_memory_field.Pin = .{},
    code: shell_memory.Pair = .{ .follows = .pc },
    breaks: shell_breaks.Breaks = .{},
    branches: shell_branches.Feed = .{},
    diff: shell_diff.State = .{},
    filmstrip: shell_filmstrip.Feed = .{},

    fn init(self: *ShellFeeds) !void {
        try self.plug.init();
        try self.camera_file.init();
        try self.memory_field.init();
    }

    fn bind(self: *ShellFeeds, shell: *shell_loop.Shell, console: *shell_console.Console, board: *shell_board.Board, files: *shell_open.Open) shell_panes.Panes {
        shell.console = console;
        shell.board = board;
        shell.board_input = &self.board_input;
        shell.devices = &self.devices;
        shell.faults = &self.faults;
        shell.camera = &self.camera;
        shell.plug = &self.plug;
        shell.camera_file = &self.camera_file;
        shell.registers = &self.registers;
        shell.edit = &self.edit;
        shell.stack = &self.stack;
        shell.memory = &self.memory;
        shell.memory_field = &self.memory_field;
        shell.code = &self.code;
        shell.breaks = &self.breaks;
        shell.files = files;
        return .{
            .console = console,
            .board = board,
            .board_input = &self.board_input,
            .devices = &self.devices,
            .faults = &self.faults,
            .camera = &self.camera,
            .plug = &self.plug,
            .camera_file = &self.camera_file,
            .registers = &self.registers,
            .edit = &self.edit,
            .memory = &self.memory,
            .memory_field = &self.memory_field,
            .code = &self.code,
            .breaks = &self.breaks,
            .stack = &self.stack,
        };
    }
};

fn local(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, window: platform.Platform, cap: ?*video_mod.capture.Capture, args: Args, startup: *shell_startup.Startup, image: ?first_image.Image, prefs: ?[]const u8) !void {
    var host_clock = wall_clock.Host.init(io);
    var board_store = shell_board_store.Store{ .io = io, .allocator = allocator, .dir = prefs };
    const rx = try allocator.alloc(u8, 2 * Env.max_frame);
    const tx = try allocator.alloc(u8, Env.max_frame);
    var boot: shell_boot.Boot = .{ .allocator = allocator, .io = io, .env = env, .window = window, .apps = args.apps[0..args.app_count], .apart = apart(args), .clock = host_clock.clock(), .rx = rx, .tx = tx, .store = &board_store };
    defer boot.deinit();
    var shell = shell_loop.Shell.init(allocator, try pane_layout.twoCore(allocator));
    if (cap) |c| c.bind(&shell);
    defer if (cap) |c| c.unbind();
    var render_buf: [64]u8 = undefined;
    shell.status.render = render_driver.status(&render_buf, render_driver.active, render_driver.gpu);
    var settings_store = shell_settings.Store{ .io = io, .allocator = allocator, .dir = prefs };
    shell.themes.choose(if (args.theme_set) args.theme else settings_store.load()); // an explicit --theme wins (RA8EMU-963)
    shell.settings = .{ .store = &settings_store, .display = settings_store.loadDisplay() };
    var layout_store = shell_layout.Store{ .io = io, .allocator = allocator, .dir = prefs };
    layout_store.restore(&shell.layout); // the saved layout replaces the default
    defer shell.deinit();
    boot.shell = &shell;
    shell.boot = boot.hook();
    var recent_store = shell_recents.Store{ .io = io, .allocator = allocator, .dir = prefs };
    var recent_list = recent_store.restore();
    shell.clock = host_clock.clock();
    var time: shell_time.Time = .{};
    shell.time = &time;
    var console = shell_console.Console.init(allocator, .{ .io = io, .dir = std.Io.Dir.cwd() });
    defer console.deinit();
    shell.console = &console;
    var board = shell_board.Board.init(allocator);
    defer board.deinit();
    shell.board = &board;
    var feeds: ShellFeeds = .{};
    try feeds.init();
    shell.board_input = &feeds.board_input;
    shell.devices = &feeds.devices;
    shell.faults = &feeds.faults;
    var camera = shell_camera.Camera.opened(io);
    if (args.camera) |spec| shell_camera.start(&camera, spec);
    shell.camera = &camera;
    shell.startup = startup;
    shell.plug = &feeds.plug;
    shell.camera_file = &feeds.camera_file;
    shell.registers = &feeds.registers;
    shell.edit = &feeds.edit;
    shell.stack = &feeds.stack;
    var source: shell_source.Pair = shell_source.Pair.init(io);
    shell.source = &source;
    shell.locals = &feeds.locals;
    shell.memory = &feeds.memory;
    shell.memory_field = &feeds.memory_field;
    shell.code = &feeds.code;
    shell.breaks = &feeds.breaks;
    shell.branches = &feeds.branches;
    shell.diff = &feeds.diff;
    shell.filmstrip = &feeds.filmstrip;
    var map: shell_map.State = .{ .allocator = allocator, .io = io };
    defer map.deinit();
    shell.map = &map;
    if (image) |named| map.build(named.path);
    var files: shell_open.Open = .{ .io = io, .allocator = allocator, .history = &recent_list };
    shell.files = &files;
    var recent_menu = shell_recent_menu.State{ .recents = &recent_list };
    shell.recent_menu = &recent_menu;
    var panes: shell_panes.Panes = .{ .console = &console, .board = &board, .board_input = &feeds.board_input, .devices = &feeds.devices, .faults = &feeds.faults, .camera = &camera, .plug = &feeds.plug, .camera_file = &feeds.camera_file, .registers = &feeds.registers, .edit = &feeds.edit, .memory = &feeds.memory, .memory_field = &feeds.memory_field, .code = &feeds.code, .breaks = &feeds.breaks, .map = &map, .stack = &feeds.stack, .timeline = &shell.timeline.?, .source = &source, .locals = &feeds.locals, .branches = &feeds.branches, .diff = &feeds.diff.view };
    shell.painter = panes.painter();
    if (image) |named| try boot.start(named);
    try driveAndSave(io, &shell, window, &boot, args.limits(), &layout_store, &recent_store, recent_list);
}

fn driveAndSave(io: std.Io, shell: *shell_loop.Shell, window: platform.Platform, boot: *shell_boot.Boot, limits: Limits, layout_store: *const shell_layout.Store, recent_store: *const shell_recents.Store, recent_list: shell_recents.List) !void {
    try driveWithLimits(io, shell, window, &boot.image, limits);
    try boot.flushHistory();
    layout_store.save(&shell.layout);
    recent_store.save(recent_list);
}

/// Runs the shell until its window closes, loading `first` once the
/// session greets. A shell with no session yet runs on empty until the
/// first image opened starts one (boot.zig) and fills `first`.
pub fn drive(io: std.Io, shell: *shell_loop.Shell, window: platform.Platform, first: *const ?first_image.Image, frames: ?u32) !void {
    return driveWithLimits(io, shell, window, first, .{ .frames = frames });
}

pub fn driveWithLimits(io: std.Io, shell: *shell_loop.Shell, window: platform.Platform, first: *const ?first_image.Image, limits: Limits) !void {
    var sent = false;
    var drawn: u32 = 0;
    var pace = wall_clock.Host.init(io);
    const clock = pace.clock();
    var pacing: shell_pace.Pace = .{};
    var start_wall_ns: ?u64 = null;
    var configured_run = false;

    while (true) {
        const began = clock.now();
        if (start_wall_ns == null) start_wall_ns = began;

        pacing.begin(shell, window, began);
        if (!try shell.step(window)) return;
        if (shell.state() == .connected and (!sent or reloadDue(shell))) {
            const link = shell.link orelse return;
            const image = first.* orelse return;
            if (!sent) if (shell.memory_field) |field| {
                field.image = shell_memory_field.Image.init(image.bytes) catch null;
            };
            try shell.status.load(link, image.path, image.bytes);
            sent = true;
            if (shell.pick) |picked| picked.reload = false;
        }

        configureRun(shell, limits, &configured_run);
        if (limits.frames != null or limits.wall_time_ns != null or limits.virtual_time_ns != null) {
            if (lost(shell)) return error.ImageNotLoaded;
        }
        if (limits.frames) |w| if (shell.status.image != null) {
            drawn += 1;
            if (drawn >= w) return;
        };
        if (limits.wall_time_ns) |w| if (clock.now() -| start_wall_ns.? >= w) return;
        if (limits.virtual_time_ns) |w| if (shell.status.image != null and shell.boardNow() >= w) return;

        if (limits.speed_milli != speed_field.max_wire) {
            try rest(io, shell, clock, pacing.end(shell, window, began, clock.now()));
        }
    }
}

fn configureRun(shell: *shell_loop.Shell, limits: Limits, configured: *bool) void {
    if (shell.status.image == null or shell.state() != .connected) return;
    const link = shell.link orelse return;
    const time = shell.time orelse return;
    if (limits.speed_milli) |milli| if (!configured.*) {
        _ = time.field.choose(link, milli) catch {};
        time.field.applied = milli;
        configured.* = true;
    };
    if (limits.auto_run and !time.run.lit) time.pressCommand(.run, link, &shell.status);
}

/// Leave what is left of the frame to the host. A session on a thread of
/// its own is heard through it: each answer wakes the shell to take it and
/// send a lit run its next slice.
fn rest(io: std.Io, shell: *shell_loop.Shell, clock: wall_clock.Clock, until_ns: u64) !void {
    while (true) {
        const now = clock.now();
        if (now >= until_ns) return;
        const worker = shell.worker orelse return io.sleep(.fromNanoseconds(until_ns - now), .awake);
        if (worker.wait(until_ns - now)) try shell.service();
    }
}

/// Whether the session answers on a thread of its own: a window someone is
/// using. A headless, scripted or frame-counted run answers on the shell's
/// thread, where every frame sees the same answers every time.
fn apart(args: Args) bool {
    return !args.headless and args.frames == null and args.gui_script == null and args.wall_time_ns == null and args.virtual_time_ns == null;
}

fn reloadDue(shell: *const shell_loop.Shell) bool {
    const pick_state = shell.pick orelse return false;
    return pick_state.reload;
}

fn lost(shell: *const shell_loop.Shell) bool {
    return switch (shell.state()) {
        .failed, .closed => true,
        .connecting, .connected => shell.status.refused == .load,
    };
}
