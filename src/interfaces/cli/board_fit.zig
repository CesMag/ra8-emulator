//! The board a run asks for on its command line, fitted before anything
//! loads: its part, its card, its panel contacts, its cell and the stick in
//! its USB jack (RA8EMU-592: out of main so the engine and Zig paths share
//! it). Each piece refuses on its own terms and says so; this only puts them
//! in order.
const std = @import("std");
const rtc_start = @import("../../session/rtc_start.zig");
const cli = @import("cli.zig");
const host_sock = @import("ra8_host").host_sock;
const host_worker = @import("ra8_host").worker;
const camera_source = @import("camera_source.zig");
const Board = @import("../../board/board.zig").Board;
const usb_disk_option = @import("usb_disk_option.zig");
const pacing = @import("../../board/run/pacing.zig");
const profile = @import("../../board/profile.zig");
const request = @import("../../components/request.zig");
const tape = @import("../../components/esp32c6_hosted/esp_tape.zig");
const tape_dir = @import("ra8_host").tape_dir;

/// A replay that met a request it has no recording for fails the run.
pub fn tapeVerdict(board: *const Board, code: u8) u8 {
    const misses = board.c6.tapeMisses();
    if (misses == 0) return code;
    std.debug.print("net-replay: {d} request(s) had no recording\n", .{misses});
    return if (code == 0) 1 else code;
}

pub fn fit(board: *Board, allocator: std.mem.Allocator, io: std.Io, options: cli.Options) !void {
    board.part = options.part;
    board.memory_monitors = .{ .cms = options.cms, .sfs = options.sfs };
    board.wire.click = options.click;
    // A run's RTC counts virtual time (RA8EMU-185): with idle fast-forward a
    // sleeping core reaches the next second edge, so the geared clock the
    // corpus was first recorded on is only kept for the RTC's own tests.
    board.clock.pace.mode = .virtual;
    if (options.rtc_start) |start| board.clock.seed(try rtc_start.resolve(start, io));
    if (options.speed) |factor| pacing.attachHost(&board.run.pacing, board.time.base.now(), io, factor);
    board.run.soak.armed = options.run_for;
    const profile_fits = try loadProfile(allocator, io, options.board_profile);
    board.external_memory = profile_fits.memory;
    try board.nor.resize(profile_fits.memory.ospi.size);
    var asks: [profile.max_fits + request.max]request.Request = undefined;
    var count: usize = 0;
    for (profile_fits.fits[0..profile_fits.count]) |fitted| {
        if (options.detach_c6 and std.mem.eql(u8, fitted.name, "c6")) continue;
        asks[count] = fitted;
        count += 1;
    }
    @memcpy(asks[count .. count + options.attach_count], options.attaches[0..options.attach_count]);
    count += options.attach_count;
    board.asks.keep(allocator, asks[0..count]);
    if (options.usb_loop) board.usb.loopBack();
    board.c6.useIo(io);
    board.c6.useNet(.of(host_sock));
    board.c6.useWorker(.of(host_worker));
    if (options.net_tape) |spec| board.c6.useTape(.init(spec.mode, .of(tape_dir, try tape_dir.open(io, spec.dir, spec.mode == .record))));
    board.capture.source = try camera_source.open(allocator, io, options.camera, &board.wire.sensor.format);
    try cli.card_setup.prepare(board, io, options.trace_sd, options.sd_path, options.sd_size_mb, options.sd_new, options.sd_label);
    try cli.card_setup.prepareSdhi(board, io, options.sdhi);
    queueTouches(board, options);
    if (options.touch_in) |path| board.touch_input.source = try cli.host_bytes.open(io, "--touch @", path);
    if (options.input_script) |path| {
        const content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
        defer allocator.free(content);
        try board.input_script.parse(content);
    }
    try setBattery(board, options);
    try usb_disk_option.apply(&board.usb, allocator, io, options.usb_disk);
    try cli.usbip_export.run.install(&board.usb, allocator, io, options.usbip);
}

/// Put the contacts the command line asked for on the touch panel. The queue
/// is the same depth as the flag allows, so nothing here can overflow it.
fn queueTouches(board: *Board, options: cli.Options) void {
    for (options.touches[0..options.touch_count]) |contact| {
        board.wire.panel.queue(contact) catch return;
    }
}

/// Tell the fuel gauge what is in the battery. A state-of-charge over full
/// is refused here rather than clamped into a number nothing measured.
fn setBattery(board: *Board, options: cli.Options) !void {
    board.wire.gauge.setBattery(options.battery) catch |err| {
        std.debug.print("--battery {d}: not a state-of-charge a cell can hold\n", .{options.battery.soc_pct});
        return err;
    };
}

/// Load a selected profile, or the shipped EK-RA8D2 default from the repo.
fn loadProfile(allocator: std.mem.Allocator, io: std.Io, path: ?[]const u8) !profile.Profile {
    const profile_path = path orelse return profile.parse(@embedFile("../../board/ek_ra8d2.board"));
    const contents = try std.Io.Dir.cwd().readFileAlloc(io, profile_path, allocator, .limited(64 * 1024));
    return profile.parse(contents);
}
