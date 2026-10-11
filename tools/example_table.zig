//! example_table runs every ELF in a directory through the emulator and prints
//! one row per image (RA8EMU-66): the verdict, how the run ended, the last SCI
//! console line, the LEDs left on and the unmodelled register count.
//!
//!   zig build examples -- EMULATOR DIR [INSTRUCTIONS]
//!
//! An image passes when its console's last line says OK or PASS. It fails when
//! the run stopped on a fault or the console says FAIL. An LED-only demo, with
//! no console and no probe, passes when one of its LEDs toggled at least
//! twice: it blinks rather than sticking (RA8EMU-398). Anything else is
//! unknown until a reader checks it against its README.
//! An image with its bench conf beside it (foo.hil.conf) runs with --console
//! and is judged first by that conf's HIL_EXPECT and HIL_EXPECT_NEGATIVE over
//! every console line, as the bench judges it (RA8EMU-400). An image with no
//! conf whose README names its pass and fail lines is judged on its last line
//! by example_expect.zig.
//! A few images need more than one budget fits; example_budgets.zig lists
//! them and the floor each runs at. A few need hardware the default board
//! does not fit; example_options.zig lists the flags that fit it.
//!
//! A dual-core example is two ELFs side by side, foo.elf for CPU0 and
//! foo_cpu1.elf for CPU1 (RA8EMU-37). The pair runs as one row, foo.elf with
//! --cpu1 foo_cpu1.elf, and the CPU1 half never gets a row of its own: run
//! alone it boots from a vector table CPU0 was supposed to release.
//!
//! A TrustZone example is two ELFs the same way, foo.elf for the Secure boot
//! and foo_ns.elf for the Non-Secure image it hands off to (RA8EMU-217). The
//! pair runs as one row, foo.elf with --ns foo_ns.elf, and the Non-Secure
//! half gets no row of its own: run alone it has no Secure world to enter it.
const std = @import("std");
pub const budgets = @import("example_budgets.zig");
pub const probes = @import("example_probes.zig");
pub const options = @import("example_options.zig");
pub const expect = @import("example_expect.zig");
pub const hil_conf = @import("hil_conf.zig");

pub const Verdict = enum { pass, fail, unknown };

pub const Row = struct {
    pub const max_leds = 8;
    /// On then off: the fewest edges that tell a blink from a stuck LED.
    pub const blink_edges = 2;

    console: ?[]const u8 = null,
    leds_on: [max_leds][]const u8 = undefined,
    led_count: usize = 0,
    unmodelled: ?u32 = null,
    stopped: ?[]const u8 = null,
    /// Some user LED toggled at least `blink_edges` times.
    blinking: bool = false,
    /// The memory-probe verdict for an image example_probes.zig lists, or
    /// whose hil.conf names a probe.
    probe: ?probes.Judgement = null,
    /// The verdict the example's own hil.conf gives, when it has one.
    hil: ?hil_conf.Judgement = null,

    pub fn leds(row: *const Row) []const []const u8 {
        return row.leds_on[0..row.led_count];
    }

    pub fn verdict(row: Row) Verdict {
        if (row.stopped != null) return .fail;
        if (row.probe) |judged| return switch (judged) {
            .pass => .pass,
            .fail => .fail,
            .unknown => .unknown,
        };
        if (row.hil) |judged| return switch (judged) {
            .pass => .pass,
            .fail => .fail,
        };
        const line = row.console orelse return if (row.blinking) .pass else .unknown;
        if (std.mem.indexOf(u8, line, "FAIL") != null) return .fail;
        if (std.mem.indexOf(u8, line, "OK") != null) return .pass;
        if (std.mem.indexOf(u8, line, "PASS") != null) return .pass;
        return .unknown;
    }
};

/// Reads one emulator report. Lines it does not know are ignored, so the report
/// can grow without breaking the table.
pub fn parse(report: []const u8) Row {
    var row: Row = .{};
    var lines = std.mem.splitScalar(u8, report, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "SCI console: ")) {
            row.console = quoted(line);
        } else if (std.mem.startsWith(u8, line, "GPIO LEDs: ")) {
            readLeds(&row, line);
        } else if (std.mem.startsWith(u8, line, "peripheral accesses: ")) {
            row.unmodelled = unmodelled(line);
        } else if (std.mem.startsWith(u8, line, "stopped at ")) {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse line.len;
            row.stopped = line["stopped at ".len..colon];
        }
    }
    return row;
}

fn quoted(line: []const u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, line, '"') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, line, '"') orelse return null;
    if (close <= open) return null;
    return line[open + 1 .. close];
}

fn readLeds(row: *Row, line: []const u8) void {
    var rest = line;
    while (std.mem.indexOfScalar(u8, rest, '[')) |open| {
        const close = std.mem.indexOfScalarPos(u8, rest, open, ']') orelse return;
        const led = rest[open + 1 .. close];
        rest = rest[close + 1 ..];
        if (edges(led) >= Row.blink_edges) row.blinking = true;
        if (std.mem.indexOf(u8, led, " ON ") == null) continue;
        if (row.led_count == Row.max_leds) return;
        const end = std.mem.indexOfScalar(u8, led, ' ') orelse led.len;
        row.leds_on[row.led_count] = led[0..end];
        row.led_count += 1;
    }
}

/// The `xN` edge count at the end of one `[LED1 BLUE P600 ON xN]` entry.
fn edges(led: []const u8) u32 {
    const at = std.mem.lastIndexOf(u8, led, " x") orelse return 0;
    return std.fmt.parseInt(u32, led[at + 2 ..], 10) catch 0;
}

fn unmodelled(line: []const u8) ?u32 {
    const tail = " distinct unmodelled registers";
    const end = std.mem.indexOf(u8, line, tail) orelse return null;
    const start = (std.mem.lastIndexOfScalar(u8, line[0..end], ' ') orelse return null) + 1;
    return std.fmt.parseInt(u32, line[start..end], 10) catch null;
}

pub fn writeHeader(writer: anytype) !void {
    try writer.writeAll("| image | verdict | end | console | LEDs on | unmodelled |\n");
    try writer.writeAll("|---|---|---|---|---|---:|\n");
}

pub fn writeRow(writer: anytype, image: []const u8, row: Row) !void {
    try writer.print("| {s} | {s} | ", .{ image, @tagName(row.verdict()) });
    if (row.stopped) |where| try writer.print("stopped at {s}", .{where}) else try writer.writeAll("budget");
    try writer.print(" | {s} | ", .{row.console orelse "-"});
    if (row.led_count == 0) try writer.writeAll("-");
    for (row.leds(), 0..) |led, index| {
        if (index > 0) try writer.writeAll(" ");
        try writer.writeAll(led);
    }
    if (row.unmodelled) |count| try writer.print(" | {d} |\n", .{count}) else try writer.writeAll(" | - |\n");
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const env = init.environ_map;

    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 3) {
        std.debug.print("usage: example_table EMULATOR DIR [INSTRUCTIONS]\n", .{});
        std.process.exit(2);
    }
    const budget: ?[]const u8 = if (args.len > 3) args[3] else null;
    const images = try listImages(allocator, io, args[2]);

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const out = &stdout.interface;
    try writeHeader(out);
    try out.flush();
    for (images) |image| {
        if (try isSecondHalf(allocator, image, images)) continue;
        const path = try std.fs.path.join(allocator, &.{ args[2], image });
        const halves = Halves{
            .cpu1 = try halfPath(allocator, args[2], try pairedWith(allocator, image, images)),
            .ns = try halfPath(allocator, args[2], try nsPairedWith(allocator, image, images)),
        };
        const conf = try readConf(allocator, io, path);
        const probe = probes.find(image) orelse confProbe(image, conf);
        var job = Job{ .emulator = args[1], .path = path, .image = image, .halves = halves, .conf = conf, .budget = budget };
        job.run = .{ .probe = probe, .console = conf != null, .extra = if (conf) |found| found.emu_args else null };
        job.run.until = untilFor(conf, probe);
        job.run.reply = if (conf) |found| found.consoleReply() else null;
        var row = try measure(allocator, io, env, job);
        // Undecided at the default budget: give a conf row the bench's own
        // modelled time once. Rows already decided keep their fast run.
        if (row.verdict() == .unknown) if (confMs(image, conf, budget)) |ms| {
            job.run.ms = ms;
            row = try measure(allocator, io, env, job);
        };
        try writeRow(out, image, row);
        try out.flush();
    }
}

fn listImages(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) ![]const []const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".elf")) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    return names.items;
}

const elf = ".elf";
const cpu1_suffix = "_cpu1.elf";
const ns_suffix = "_ns.elf";

/// The second images a row runs with, as paths.
const Halves = struct {
    cpu1: ?[]const u8 = null,
    ns: ?[]const u8 = null,
};

/// foo.elf's CPU1 half, foo_cpu1.elf. Caller owns the name.
pub fn cpu1Name(allocator: std.mem.Allocator, image: []const u8) ![]const u8 {
    return halfName(allocator, image, cpu1_suffix);
}

/// foo.elf's Non-Secure half, foo_ns.elf. Caller owns the name.
pub fn nsName(allocator: std.mem.Allocator, image: []const u8) ![]const u8 {
    return halfName(allocator, image, ns_suffix);
}

fn halfName(allocator: std.mem.Allocator, image: []const u8, suffix: []const u8) ![]const u8 {
    const stem = image[0 .. image.len - elf.len];
    return std.mem.concat(allocator, u8, &.{ stem, suffix });
}

/// True for foo_cpu1.elf or foo_ns.elf when foo.elf sits beside it: that
/// image is the second half of a pair, not an example of its own.
pub fn isSecondHalf(allocator: std.mem.Allocator, image: []const u8, names: []const []const u8) !bool {
    return try hasPartner(allocator, image, cpu1_suffix, names) or
        try hasPartner(allocator, image, ns_suffix, names);
}

fn hasPartner(allocator: std.mem.Allocator, image: []const u8, suffix: []const u8, names: []const []const u8) !bool {
    if (!std.mem.endsWith(u8, image, suffix)) return false;
    const partner = try std.mem.concat(allocator, u8, &.{ image[0 .. image.len - suffix.len], elf });
    defer allocator.free(partner);
    return contains(names, partner);
}

/// The CPU1 half of `image` in the directory, when the directory has one.
/// A CPU0 image whose own stem ends in _cpu1 (threadx_cpu1.elf) still pairs:
/// main() drops true second halves with isSecondHalf before asking.
pub fn pairedWith(allocator: std.mem.Allocator, image: []const u8, names: []const []const u8) !?[]const u8 {
    return present(allocator, try cpu1Name(allocator, image), names);
}

/// The Non-Secure half of `image` in the directory, when it has one.
pub fn nsPairedWith(allocator: std.mem.Allocator, image: []const u8, names: []const []const u8) !?[]const u8 {
    return present(allocator, try nsName(allocator, image), names);
}

fn present(allocator: std.mem.Allocator, name: []const u8, names: []const []const u8) ?[]const u8 {
    if (contains(names, name)) return name;
    allocator.free(name);
    return null;
}

fn contains(names: []const []const u8, wanted: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, wanted)) return true;
    }
    return false;
}

fn halfPath(allocator: std.mem.Allocator, dir: []const u8, name: ?[]const u8) !?[]const u8 {
    return try std.fs.path.join(allocator, &.{ dir, name orelse return null });
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// foo.elf's bench conf, copied beside it as foo.hil.conf (RA8EMU-400).
pub fn confName(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.mem.concat(allocator, u8, &.{ path[0 .. path.len - elf.len], ".hil.conf" });
}

/// The console line that may end a conf run early. A run that also carries
/// a memory probe keeps its budget: the probe reads what advances after the
/// expected line (secure_boot_ns_hil's Non-secure world runs after it).
pub fn untilFor(conf: ?hil_conf.Conf, probe: ?probes.Probe) ?[]const u8 {
    if (probe != null) return null;
    return (conf orelse return null).untilLine();
}

fn confProbe(image: []const u8, conf: ?hil_conf.Conf) ?probes.Probe {
    const found = conf orelse return null;
    return probes.fromConf(image, found.probe_symbol, found.probe_min_advance, found.probe_failure_symbol, found.probe_max_failure);
}

fn readConf(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?hil_conf.Conf {
    const text = std.Io.Dir.cwd().readFileAlloc(io, try confName(allocator, path), allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return hil_conf.parse(text);
}

/// One row's run: the images, its conf and the caller's budget.
const Job = struct {
    emulator: []const u8,
    path: []const u8,
    image: []const u8,
    halves: Halves,
    conf: ?hil_conf.Conf,
    budget: ?[]const u8,
    run: Run = .{},
};

/// Runs a job and judges the report into a row.
fn measure(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, job: Job) !Row {
    const budget = budgets.pick(job.image, job.budget);
    const report = try runImage(allocator, io, env, job.emulator, job.path, job.halves, job.run, budget);
    var row = parse(report);
    if (job.run.probe) |wanted| row.probe = probes.judge(wanted, report);
    // An undecided conf probe leaves the row to the console and LEDs.
    if (row.probe == .unknown and probes.find(job.image) == null) row.probe = null;
    if (job.conf) |found| row.hil = hil_conf.judge(found, report);
    // No conf: the README's own pass and fail lines, when it names them.
    if (job.conf == null) if (expect.find(job.image)) |found| {
        row.hil = expect.judge(found, row.console);
    };
    return row;
}

/// What a row asks of the emulator besides its images and budget.
const Run = struct {
    probe: ?probes.Probe = null,
    console: bool = false,
    ms: ?u32 = null,
    /// The conf's HIL_EMU_ARGS, split on spaces into extra emulator flags.
    extra: ?[]const u8 = null,
    /// The conf's uart_scrape line: the run ends once the console prints it.
    until: ?[]const u8 = null,
    /// The conf's `--console-reply`, e.g. the bench's Wi-Fi provisioning.
    reply: ?[]const u8 = null,
};

/// The bench's modelled time for a conf row (RA8EMU-400), used to retry a
/// row the default budget left unknown. Only when no
/// instruction budget applies and the row's own flags set no --ms: a caller
/// budget or an example_budgets.zig floor passes --instructions, which the
/// emulator lets win over --ms.
fn confMs(image: []const u8, conf: ?hil_conf.Conf, budget: ?[]const u8) ?u32 {
    if (budgets.pick(image, budget) != null) return null;
    for (options.flags(image)) |flag| {
        if (std.mem.eql(u8, flag, "--ms")) return null;
    }
    return (conf orelse return null).floorMs();
}

fn runImage(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, emulator: []const u8, path: []const u8, halves: Halves, run: Run, budget: ?[]const u8) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(allocator, &.{ emulator, path });
    const image = std.fs.path.basename(path);
    try argv.appendSlice(allocator, options.flags(image));
    if (options.cardImage(image, env)) |card| try argv.appendSlice(allocator, &.{ "--sd", card });
    if (try cardDirPath(allocator, io, path)) |dir| try argv.appendSlice(allocator, &.{ "--sd-dir", dir });
    for (options.appsFor(image)) |app| {
        const app_path = try std.fs.path.join(allocator, &.{ std.fs.path.dirname(path) orelse ".", app });
        std.Io.Dir.cwd().access(io, app_path, .{}) catch continue;
        try argv.appendSlice(allocator, &.{ "--app", app_path });
    }
    if (halves.cpu1) |cpu1| try argv.appendSlice(allocator, &.{ "--cpu1", cpu1 });
    if (halves.ns) |ns| try argv.appendSlice(allocator, &.{ "--ns", ns });
    if (run.probe) |wanted| try argv.appendSlice(allocator, &.{ probes.flag(wanted.symbol), wanted.symbol });
    if (run.probe) |wanted| if (wanted.failure) |name| try argv.appendSlice(allocator, &.{ probes.flag(name), name });
    if (run.console) try argv.append(allocator, "--console");
    if (run.until) |text| try argv.appendSlice(allocator, &.{ "--until", text });
    if (run.reply) |spec| try argv.appendSlice(allocator, &.{ "--console-reply", spec });
    if (run.extra) |extra| {
        var words = std.mem.tokenizeScalar(u8, extra, ' ');
        while (words.next()) |word| try argv.append(allocator, word);
    }
    if (run.ms) |ms| try argv.appendSlice(allocator, &.{ "--ms", try std.fmt.allocPrint(allocator, "{d}", .{ms}) });
    if (budget) |count| try argv.appendSlice(allocator, &.{ "--instructions", count });
    const limit: std.Io.Limit = .limited(16 * 1024 * 1024);
    const result = try std.process.run(allocator, io, .{ .argv = argv.items, .stdout_limit = limit, .stderr_limit = limit });
    return std.mem.concat(allocator, u8, &.{ result.stdout, "\n", result.stderr });
}

/// The existing card directory beside path that options.cardDir names.
fn cardDirPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?[]const u8 {
    const name = options.cardDir(std.fs.path.basename(path)) orelse return null;
    const dir = try std.fs.path.join(allocator, &.{ std.fs.path.dirname(path) orelse ".", name });
    std.Io.Dir.cwd().access(io, dir, .{}) catch return null;
    return dir;
}
