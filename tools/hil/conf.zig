//! Reads an example's hil.conf (RA8EMU-400).
//!
//! The bench judges each example from the hil.conf beside its sources:
//! HIL_EXPECT is the console text a pass prints, HIL_EXPECT_NEGATIVE a
//! `|`-separated list whose any match is a fail, and the HIL_PROBE_* keys
//! name a counter J-Link reads instead. The table reads the same file, copied
//! beside the ELF as NAME.hil.conf, so its verdicts follow the bench's.
//!
//! Lines are KEY=VALUE, with `#` comments and optional double quotes around
//! the value. Keys this file does not name are ignored. Every slice points
//! into the text it was parsed from.
const std = @import("std");
pub const alive = @import("alive.zig");

pub const Conf = struct {
    mode: ?[]const u8 = null,
    expect: ?[]const u8 = null,
    expect_negative: ?[]const u8 = null,
    timeout_s: ?u32 = null,
    probe_symbol: ?[]const u8 = null,
    probe_min_advance: ?u32 = null,
    probe_failure_symbol: ?[]const u8 = null,
    probe_max_failure: ?u32 = null,
    emu_args: ?[]const u8 = null,
    probe_seconds: ?u32 = null,
    probe_boot_s: ?u32 = null,
    provision_wifi: bool = false,

    /// The longest modelled time the table gives a conf row: the 60 s scrape
    /// the bench gives wdt_reset_recovery_demo (a 25 s watchdog countdown and
    /// a second boot), import_reader and usb_printer_vendor. Only
    /// fs_format_mount's 240 s format is cut short, so an image spinning in a
    /// busy loop still cannot stall the whole table.
    pub const max_floor_ms: u32 = 60_000;

    /// The bench's own windows when a conf names none: ra8-firmware's
    /// scripts/hil/all.sh scrapes the console for 10 s and watches a probe
    /// for 3 s.
    pub const bench_scrape_s: u32 = 10;
    pub const bench_probe_s: u32 = 3;

    /// How much modelled time the bench gives this example: a memory probe's
    /// boot dwell plus its window, else the console scrape's timeout, each
    /// falling back to the bench default for its mode. Null for any other
    /// mode that names neither.
    pub fn floorMs(conf: Conf) ?u32 {
        const seconds = conf.windowS() orelse return null;
        return @min(seconds * 1000, max_floor_ms);
    }

    fn windowS(conf: Conf) ?u32 {
        const boot = conf.probe_boot_s orelse 0;
        if (conf.probe_seconds) |window| return window + boot;
        if (conf.timeout_s) |timeout| return timeout;
        const mode = conf.mode orelse return null;
        if (std.mem.eql(u8, mode, "jlink_memprobe")) return bench_probe_s + boot;
        if (std.mem.eql(u8, mode, "uart_scrape")) return bench_scrape_s;
        return null;
    }

    /// HIL_MODE=alive: the run passes unless its console says otherwise.
    /// The line a uart_scrape run ends on, handed to the emulator as
    /// `--until`: the bench stops scraping at the first match and checks
    /// HIL_EXPECT_NEGATIVE over what it captured up to there. Null for any
    /// other mode, or a conf with no HIL_EXPECT.
    pub fn untilLine(conf: Conf) ?[]const u8 {
        if (!std.mem.eql(u8, conf.mode orelse return null, "uart_scrape")) return null;
        const text = conf.expect orelse return null;
        return if (text.len == 0) null else text;
    }

    /// HIL_PROVISION_WIFI=1: the bench answers ra8_net_provision's "READY v1"
    /// with its Wi-Fi credentials. The table types the same RA8NET1 line
    /// (ssid "bench", password "emulator", hex-encoded) back through
    /// `--console-reply`; the C6 model's AP takes any (RA8EMU-626).
    pub const bench_wifi_reply = "READY v1=RA8NET1:62656e63:656d756c61746f72:";

    /// The `--console-reply` spec this conf asks for, if any.
    pub fn consoleReply(conf: Conf) ?[]const u8 {
        return if (conf.provision_wifi) bench_wifi_reply else null;
    }

    pub fn isAlive(conf: Conf) bool {
        return std.mem.eql(u8, conf.mode orelse return false, "alive");
    }

    /// Whether `console` carries any HIL_EXPECT_NEGATIVE alternative.
    pub fn refused(conf: Conf, console: []const u8) bool {
        const list = conf.expect_negative orelse return false;
        var words = std.mem.splitScalar(u8, list, '|');
        while (words.next()) |word| {
            if (word.len != 0 and std.mem.indexOf(u8, console, word) != null) return true;
        }
        return false;
    }

    /// Whether `console` carries the HIL_EXPECT text.
    pub fn expected(conf: Conf, console: []const u8) bool {
        const text = conf.expect orelse return false;
        return std.mem.indexOf(u8, console, text) != null;
    }
};

pub fn parse(text: []const u8) Conf {
    var conf: Conf = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        put(&conf, std.mem.trim(u8, line[0..eq], " \t"), unquote(std.mem.trim(u8, line[eq + 1 ..], " \t")));
    }
    return conf;
}

fn put(conf: *Conf, key: []const u8, value: []const u8) void {
    const eql = std.mem.eql;
    if (eql(u8, key, "HIL_MODE")) conf.mode = value;
    if (eql(u8, key, "HIL_EXPECT")) conf.expect = value;
    if (eql(u8, key, "HIL_EXPECT_NEGATIVE")) conf.expect_negative = value;
    if (eql(u8, key, "HIL_TIMEOUT_S")) conf.timeout_s = number(value);
    if (eql(u8, key, "HIL_PROBE_SYMBOL")) conf.probe_symbol = value;
    if (eql(u8, key, "HIL_PROBE_MIN_ADVANCE")) conf.probe_min_advance = number(value);
    if (eql(u8, key, "HIL_PROBE_FAILURE_SYMBOL")) conf.probe_failure_symbol = value;
    if (eql(u8, key, "HIL_PROBE_MAX_FAILURE")) conf.probe_max_failure = number(value);
    if (eql(u8, key, "HIL_EMU_ARGS")) conf.emu_args = value;
    if (eql(u8, key, "HIL_PROBE_SECONDS")) conf.probe_seconds = number(value);
    if (eql(u8, key, "HIL_PROBE_BOOT_S")) conf.probe_boot_s = number(value);
    if (eql(u8, key, "HIL_PROVISION_WIFI")) conf.provision_wifi = eql(u8, value, "1");
}

fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') return value[1 .. value.len - 1];
    return value;
}

fn number(value: []const u8) ?u32 {
    return std.fmt.parseInt(u32, value, 10) catch null;
}

/// What a conf says about one run, read from the `console> ` lines the
/// emulator streams under --console.
pub const Judgement = enum { pass, fail };

pub const console_prefix = "console> ";

/// A negative anywhere in the console fails the run, the bench's rule; else
/// the expected text anywhere passes it, and an alive conf passes a run its
/// console does not refuse. Null when the conf decides nothing.
pub fn judge(conf: Conf, report: []const u8) ?Judgement {
    var passed = false;
    var lines = std.mem.splitScalar(u8, report, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, console_prefix)) continue;
        const text = line[console_prefix.len..];
        if (conf.refused(text)) return .fail;
        if (conf.isAlive() and alive.refused(text)) return .fail;
        if (conf.expected(text)) passed = true;
    }
    return if (passed or conf.isAlive()) .pass else null;
}
