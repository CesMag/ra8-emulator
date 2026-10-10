//! `ctl events [--topic uart|stop]... [--until TEXT] [--timeout D]`
//! (RA8EMU-757): subscribe, run the core in budget chunks and print each
//! event as it arrives. Exit 0 once TEXT appears in the UART output (or at
//! the timeout when no TEXT was given), 1 on a timeout while waiting for
//! TEXT or on any stop that is not the end of a chunk.
const std = @import("std");
const proto = @import("ra8_rpc").session_rpc;
const Client = @import("ctl_client.zig").Client;
const out = @import("ctl_print.zig");

/// Instructions per run call; small enough that the server's event queue
/// (128 events) holds a chunk's UART output.
pub const chunk = 100_000;
/// The longest TEXT, which bounds the carried-over UART window.
const max_until = 256;

pub const Options = struct {
    uart: bool = false,
    stop: bool = false,
    until: ?[]const u8 = null,
    timeout_ms: i64 = 10_000,
};

pub fn parse(args: []const []const u8) !Options {
    var options: Options = .{};
    var index: usize = 0;
    while (index < args.len) : (index += 2) {
        if (index + 1 >= args.len) return error.BadArguments;
        const name = args[index];
        const value = args[index + 1];
        if (std.mem.eql(u8, name, "--topic")) {
            const topic = std.meta.stringToEnum(enum { uart, stop }, value) orelse return error.UnknownTopic;
            if (topic == .uart) options.uart = true else options.stop = true;
        } else if (std.mem.eql(u8, name, "--until")) {
            if (value.len == 0 or value.len > max_until) return error.BadUntil;
            options.until = value;
        } else if (std.mem.eql(u8, name, "--timeout")) {
            options.timeout_ms = try parseDuration(value);
        } else return error.BadArguments;
    }
    if (!options.uart and !options.stop) options.uart = true;
    if (options.until != null) options.uart = true;
    return options;
}

/// `500ms`, `30s`, or a bare number of seconds.
pub fn parseDuration(word: []const u8) !i64 {
    const ms = std.mem.endsWith(u8, word, "ms");
    const digits = if (ms) word[0 .. word.len - 2] else std.mem.trimEnd(u8, word, "s");
    const value = try std.fmt.parseInt(i64, digits, 10);
    if (value <= 0 or value > 86_400_000) return error.BadDuration;
    return if (ms) value else std.math.mul(i64, value, 1000) catch error.BadDuration;
}

/// The tail of the UART output, kept so TEXT split across events still matches.
const Window = struct {
    bytes: [2 * max_until]u8 = undefined,
    len: usize = 0,

    fn feed(self: *Window, until: []const u8, data: []const u8) bool {
        for (data) |byte| {
            if (self.len == self.bytes.len) {
                std.mem.copyForwards(u8, self.bytes[0..max_until], self.bytes[max_until..]);
                self.len = max_until;
            }
            self.bytes[self.len] = byte;
            self.len += 1;
            if (std.mem.endsWith(u8, self.bytes[0..self.len], until)) return true;
        }
        return false;
    }
};

/// Run `options` on `client` and return the exit code.
pub fn watch(client: *Client, w: anytype, json: bool, options: Options) !u8 {
    if (options.uart) _ = try client.call(proto.Ack, proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .uart });
    _ = try client.call(proto.Ack, proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .stop });
    const deadline = client.nowMs() + options.timeout_ms;
    var window: Window = .{};
    while (client.nowMs() < deadline) {
        _ = try client.call(proto.Ack, proto.Run, .run, .{ .core = .cpu0, .mode = .cont, .budget = chunk });
        while (true) {
            const left = deadline - client.nowMs();
            const sent = try client.event(@max(left, 1)) orelse return timedOut(w, json, options);
            if (sent.topic == @backingInt(proto.Topic.uart)) {
                const uart = try proto.decode(proto.Uart, sent.payload);
                try out.uart(w, json, uart);
                const until = options.until orelse continue;
                if (window.feed(until, uart.bytes)) return 0;
                continue;
            }
            if (sent.topic != @backingInt(proto.Topic.stop)) continue;
            const stop = try proto.decode(proto.Stopped, sent.payload);
            if (stop.reason == .count) {
                if (options.stop) try out.stopped(w, json, stop);
                break;
            }
            try out.stopped(w, json, stop);
            return 1;
        }
    }
    return timedOut(w, json, options);
}

fn timedOut(w: anytype, json: bool, options: Options) !u8 {
    const until = options.until orelse return 0;
    try out.timeout(w, json, until);
    return 1;
}
