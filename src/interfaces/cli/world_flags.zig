//! The flags that describe the world the board comes up in: the card on the
//! SPI line, the gauge, the panel, the USB jack and the part's memory split.
//!
//! Its own file so cli.zig keeps room for flags (RA8EMU-428). They read the
//! same way the rest do.
const std = @import("std");
const cli = @import("cli.zig");
const touch_spec = @import("ra8_session").touch_spec;
const request = @import("ra8_components").request;
const fault_spec = @import("ra8_components").fault_spec;
const source_spec = @import("ra8_host").camera.source_spec;
const sci_reply = @import("ra8_chip").periph.sci.reply;
const rtc_start = @import("ra8_session").rtc_start;
const speed = @import("ra8_board").run.speed;
const duration = @import("ra8_session").duration;
const timebase = @import("ra8_chip").periph.timebase;

const Options = cli.Options;
const card_setup = cli.card_setup;

/// Whether the argument at `index` was one of these flags. True walks
/// `index` past any value it took; false leaves it where it was.
pub fn parse(options: *Options, argv: []const []const u8, index: *usize) !bool {
    if (try parseSplit(options, argv, index)) return true;
    if (try parseSdhi(options, argv, index)) return true;
    if (try @import("audio_out.zig").parse(&options.audio, argv, index)) return true;
    const flag = argv[index.*];
    if (std.mem.eql(u8, flag, "--console")) {
        options.console = true;
    } else if (std.mem.eql(u8, flag, "--console-reply")) {
        options.console_reply = try sci_reply.Reply.parse(try next(argv, index));
    } else if (std.mem.eql(u8, flag, "--trace-sd")) {
        options.trace_sd = true;
    } else if (std.mem.eql(u8, flag, "--charge")) {
        options.battery.charging = true;
    } else if (std.mem.eql(u8, flag, "--click")) {
        options.click = true;
    } else if (std.mem.eql(u8, flag, "--bus-errors") or std.mem.eql(u8, flag, "--no-bus-errors")) {
        options.bus_errors = flag[2] == 'b';
    } else if (std.mem.eql(u8, flag, "--blocks") or std.mem.eql(u8, flag, "--no-blocks")) {
        options.blocks = flag[2] == 'b';
    } else if (std.mem.eql(u8, flag, "--sd-size")) {
        options.sd_size_mb = try std.fmt.parseInt(u32, try next(argv, index), 10);
    } else if (std.mem.eql(u8, flag, "--sd") or std.mem.eql(u8, flag, "--sd-save")) {
        options.sd_path = try next(argv, index);
        options.sd_save = flag.len > "--sd".len;
    } else if (std.mem.eql(u8, flag, "--dump-sd")) {
        options.dump_sd = try std.fmt.parseInt(u32, try next(argv, index), 0);
    } else if (std.mem.eql(u8, flag, "--usb-loop")) {
        options.usb_loop = true;
    } else if (std.mem.eql(u8, flag, "--usb-disk")) {
        options.usb_disk = try next(argv, index);
    } else if (std.mem.eql(u8, flag, "--usbip")) {
        options.usbip = try std.fmt.parseInt(u16, try next(argv, index), 10);
    } else if (std.mem.eql(u8, flag, "--battery")) {
        options.battery.soc_pct = try std.fmt.parseInt(u8, try next(argv, index), 10);
    } else if (std.mem.eql(u8, flag, "--sd-new")) {
        options.sd_new, options.sd_label = try card_setup.newSpec(try next(argv, index));
    } else if (std.mem.eql(u8, flag, "--realtime")) {
        options.speed = 1000;
    } else if (std.mem.eql(u8, flag, "--speed")) {
        options.speed = try speedArg(try next(argv, index));
    } else if (std.mem.eql(u8, flag, "--run-for")) {
        options.ms = try runFor(try next(argv, index));
        options.run_for = true;
    } else if (std.mem.eql(u8, flag, "--idle-skip") or std.mem.eql(u8, flag, "--no-idle-skip")) {
        options.idle_skip = flag[2] == 'i';
    } else if (std.mem.eql(u8, flag, "--rtc-start")) {
        options.rtc_start = try rtcStart(try next(argv, index));
    } else if (std.mem.eql(u8, flag, "--camera-source")) {
        const allow = options.camera.allow_webcam;
        options.camera = try camera(try next(argv, index));
        options.camera.allow_webcam = allow;
    } else if (std.mem.eql(u8, flag, "--allow-webcam")) {
        options.camera.allow_webcam = true;
    } else if (std.mem.eql(u8, flag, "--board-profile")) {
        options.board_profile = try next(argv, index);
    } else if (std.mem.eql(u8, flag, "--detach")) {
        const name = try next(argv, index);
        if (!std.mem.eql(u8, name, "c6")) return error.UnknownFittedPart;
        options.detach_c6 = true;
    } else if (std.mem.eql(u8, flag, "--net-record") or std.mem.eql(u8, flag, "--net-replay")) {
        if (options.net_tape != null) return error.NetTapeTwice;
        options.net_tape = .{ .dir = try next(argv, index), .mode = if (std.mem.eql(u8, flag, "--net-record")) .record else .replay };
    } else if (std.mem.eql(u8, flag, "--attach")) {
        try attach(options, try next(argv, index));
    } else if (std.mem.eql(u8, flag, "--fault")) {
        try fault(options, try next(argv, index));
    } else if (std.mem.eql(u8, flag, "--faults")) {
        options.faults = try next(argv, index);
    } else if (std.mem.eql(u8, flag, "--input-script")) {
        options.input_script = try next(argv, index);
    } else if (touch_spec.claims(flag)) {
        try touch_spec.take(options, flag, try next(argv, index));
    } else return false;
    return true;
}

/// `--cms N` and `--sfs N`: the Secure code MRAM and SiP flash areas in
/// 32 KB units, as CMSAMON/SFSAMON report them (HUM 51.8.11/51.8.12).
fn parseSplit(options: *Options, argv: []const []const u8, index: *usize) !bool {
    const flag = argv[index.*];
    if (std.mem.eql(u8, flag, "--cms")) {
        options.cms = try area(try next(argv, index));
    } else if (std.mem.eql(u8, flag, "--sfs")) {
        options.sfs = try area(try next(argv, index));
    } else return false;
    return true;
}

/// The SDHI card's flags: `--sd-image`, `--sd-writable`, `--sd-dir` and
/// the `--app` files laid in its root (RA8EMU-1138).
fn parseSdhi(options: *Options, argv: []const []const u8, index: *usize) !bool {
    const flag = argv[index.*];
    if (std.mem.eql(u8, flag, "--sd-image")) {
        options.sdhi.image = try next(argv, index);
    } else if (std.mem.eql(u8, flag, "--sd-dir")) {
        options.sdhi.dir = try next(argv, index);
    } else if (std.mem.eql(u8, flag, "--app")) {
        try options.sdhi.addApp(try next(argv, index));
    } else if (std.mem.eql(u8, flag, "--sd-writable")) {
        options.sdhi.writable = true;
    } else return false;
    return true;
}

/// One `--attach` ask, queued after any before it. A bad spec says why.
fn attach(options: *Options, spec: []const u8) !void {
    if (options.attach_count >= options.attaches.len) return error.TooManyAttaches;
    options.attaches[options.attach_count] = request.parse(spec) catch |err| {
        std.debug.print("--attach {s}: {s}\n", .{ spec, @errorName(err) });
        return err;
    };
    options.attach_count += 1;
}

/// One `--fault` ask, put on the `--attach` ask before it that names the
/// same part. A bad spec, or one with no such ask, says why.
fn fault(options: *Options, spec: []const u8) !void {
    const wanted = fault_spec.parse(spec) catch |err| {
        std.debug.print("--fault {s}: {s}\n", .{ spec, @errorName(err) });
        return err;
    };
    if (wanted.target.name.len == 0) {
        // A fitted part has no --attach ask to ride on, so it gets its own.
        if (options.attach_count >= options.attaches.len) return error.TooManyAttaches;
        var ask = wanted.target;
        ask.fault = wanted.mode;
        options.attaches[options.attach_count] = ask;
        options.attach_count += 1;
        return;
    }
    fault_spec.place(options.attaches[0..options.attach_count], wanted) catch |err| {
        std.debug.print("--fault {s}: no --attach before it names that part\n", .{spec});
        return err;
    };
}

/// One `--speed` factor. A bad one says why before the run starts.
fn speedArg(text: []const u8) !?u64 {
    return speed.parse(text) catch |err| {
        std.debug.print("--speed {s}: {s}\n", .{ text, speed.describe(err) });
        return err;
    };
}

/// One `--run-for` duration as a `--ms` window (RA8EMU-762). The run then
/// ends after that much of the image's own time, counted in its SysTick
/// periods at whatever clock it runs, and the instruction ceiling `--ms`
/// sizes covers an image that never arms SysTick. Durations are whole
/// seconds or more, so the milliseconds are exact. A bad one says why
/// before the run starts.
fn runFor(text: []const u8) !u64 {
    const ns = duration.parse(text) catch |err| {
        std.debug.print("--run-for {s}: {s}\n", .{ text, duration.describe(err) });
        return err;
    };
    return ns / std.time.ns_per_ms;
}

/// One `--rtc-start` value. A bad one says why before the run starts.
fn rtcStart(text: []const u8) !rtc_start.Start {
    return rtc_start.parse(text) catch |err| {
        std.debug.print("--rtc-start {s}: {s}\n", .{ text, @errorName(err) });
        return err;
    };
}

/// One `--camera-source` spec. A bad one says why before the run starts.
fn camera(spec: []const u8) !source_spec.Spec {
    return source_spec.parse(spec) catch |err| {
        std.debug.print("--camera-source {s}: {s}\n", .{ spec, @errorName(err) });
        return err;
    };
}

/// A nine-bit area, decimal or 0x-prefixed; anything past 0x1FF is refused.
pub fn area(text: []const u8) !u9 {
    return std.fmt.parseInt(u9, text, 0) catch error.BadValue;
}

/// The argument after the flag, or a refusal when the flag was last.
pub fn next(argv: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= argv.len) return error.MissingValue;
    return argv[index.*];
}
