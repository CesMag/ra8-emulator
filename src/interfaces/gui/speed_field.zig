//! The time bar's speed field (RA8EMU-808): type a factor (0.25, 5, 100) or
//! `max`, and Enter applies it to the session. Anything `--speed` would
//! refuse is refused here, in the field, and never reaches the session; the
//! range check is session_speed's, not a copy of it.
const std = @import("std");
const proto = @import("ra8_rpc").session_rpc;
const session_speed = @import("ra8_session").speed;
const session_link = @import("session_link.zig");
const hex_entry = @import("ui/hex_entry.zig");
const Link = session_link.Link;
const Arrival = session_link.Arrival;
const Env = proto.Client.Env;

pub const codes = hex_entry.codes;
pub const max_chars: usize = 12;
/// Thousandths of real time on the wire; zero is `max`, the unpaced speed.
pub const max_wire: u64 = 0;
pub const real_time: u64 = 1000;

/// The text as thousandths for the wire, or null when `--speed` would refuse it.
pub fn parse(text: []const u8) ?u64 {
    if (std.ascii.eqlIgnoreCase(text, "max")) return max_wire;
    const factor = std.fmt.parseFloat(f64, text) catch return null;
    const change = session_speed.Change.of(factor, 1) catch return null;
    return change.milli orelse max_wire;
}

/// A factor in thousandths as the field shows it: "max", "1x", "0.25x".
pub fn format(milli: u64, buf: []u8) ![]const u8 {
    if (milli == max_wire) return std.fmt.bufPrint(buf, "max", .{});
    const whole = milli / 1000;
    const frac = milli % 1000;
    if (frac == 0) return std.fmt.bufPrint(buf, "{d}x", .{whole});
    var digits: [3]u8 = undefined;
    _ = try std.fmt.bufPrint(&digits, "{d:0>3}", .{frac});
    return std.fmt.bufPrint(buf, "{d}.{s}x", .{ whole, std.mem.trimEnd(u8, &digits, "0") });
}

pub const Refusal = enum {
    invalid,
    session,

    pub fn message(self: Refusal) []const u8 {
        return switch (self) {
            .invalid => "not a speed (0.001 to 1000000, or max)",
            .session => "the session refused the speed",
        };
    }
};

pub const Outcome = enum { typing, sent, refused, cancel };

pub const Field = struct {
    core: proto.Core = .cpu0,
    chars: [max_chars]u8 = undefined,
    len: usize = 0,
    /// The factor the session last took, in thousandths.
    applied: u64 = real_time,
    asked: u64 = real_time,
    ask_id: ?u32 = null,
    refused: ?Refusal = null,

    pub fn text(self: *const Field) []const u8 {
        return self.chars[0..self.len];
    }

    /// Keeps digits, one dot and the letters of `max`; drops everything else.
    pub fn typed(self: *Field, input: []const u8) void {
        for (input) |byte| {
            if (self.len == max_chars) return;
            const lower = std.ascii.toLower(byte);
            const keep = std.ascii.isDigit(lower) or lower == 'm' or lower == 'a' or lower == 'x' or
                (lower == '.' and std.mem.indexOfScalar(u8, self.text(), '.') == null);
            if (!keep) continue;
            self.chars[self.len] = lower;
            self.len += 1;
            self.refused = null;
        }
    }

    /// Enter sends a valid speed and refuses the rest in the field, Escape
    /// drops what was typed, Backspace drops a character.
    pub fn key(self: *Field, link: *Link, code: u32) !Outcome {
        switch (code) {
            codes.enter => {
                if (self.len == 0) return .cancel;
                const milli = parse(self.text()) orelse {
                    self.refused = .invalid;
                    return .refused;
                };
                self.ask_id = try link.send(proto.SetSpeed, .set_speed, .{ .core = self.core, .milli = milli });
                self.asked = milli;
                return .sent;
            },
            codes.escape => {
                self.len = 0;
                self.refused = null;
                return .cancel;
            },
            codes.backspace, codes.delete => self.len -|= 1,
            else => {},
        }
        return .typing;
    }

    /// Takes the session's answer to the last speed sent.
    pub fn observe(self: *Field, arrival: Arrival) void {
        const response = switch (arrival) {
            .response => |response| response,
            .event => return,
        };
        if (response.id != self.ask_id) return;
        self.ask_id = null;
        if (response.result == .err) {
            self.refused = .session;
            return;
        }
        self.applied = self.asked;
        self.len = 0;
    }

    /// What the field reads: the typed text while editing, else the speed in use.
    pub fn shown(self: *const Field, buf: []u8) ![]const u8 {
        if (self.len > 0) return std.fmt.bufPrint(buf, "{s}", .{self.text()});
        return format(self.applied, buf);
    }
};
