//! The time bar's speed field (RA8EMU-808): type a factor (0.25, 5, 100) or
//! `max`, or choose from common presets in the dropdown, and apply it to
//! the session. Anything `--speed` would refuse is refused here, in the
//! field, and never reaches the session; the range check is session_speed's,
//! not a copy of it.
const std = @import("std");
const proto = @import("ra8_rpc").session.rpc;
const session_speed = @import("ra8_session").speed;
const session_link = @import("session_link.zig");
const hex_entry = @import("ui/hex_entry.zig");
const Link = session_link.Link;
const Arrival = session_link.Arrival;
const Env = proto.Client.Env;

pub const codes = struct {
    pub const enter: u32 = hex_entry.codes.enter;
    pub const kp_enter: u32 = 0x40000058;
    pub const escape: u32 = hex_entry.codes.escape;
    pub const backspace: u32 = hex_entry.codes.backspace;
    pub const delete: u32 = hex_entry.codes.delete;
};
pub const max_chars: usize = 12;
/// Thousandths of real time on the wire; zero is `max`, the unpaced speed.
pub const max_wire: u64 = 0;
pub const real_time: u64 = 1000;

pub const Preset = struct {
    label: []const u8,
    milli: u64,
};

/// Common speeds selectable from the dropdown.
pub const presets = [_]Preset{
    .{ .label = "0.1x", .milli = 100 },
    .{ .label = "0.25x", .milli = 250 },
    .{ .label = "0.5x", .milli = 500 },
    .{ .label = "1x", .milli = 1000 },
    .{ .label = "2x", .milli = 2000 },
    .{ .label = "5x", .milli = 5000 },
    .{ .label = "10x", .milli = 10_000 },
    .{ .label = "max", .milli = max_wire },
};

/// The text as thousandths for the wire, or null when `--speed` would refuse it.
pub fn parse(text: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(trimmed, "max")) return max_wire;
    const num_str = if (trimmed.len > 1 and (trimmed[trimmed.len - 1] == 'x' or trimmed[trimmed.len - 1] == 'X'))
        trimmed[0 .. trimmed.len - 1]
    else
        trimmed;
    const factor = std.fmt.parseFloat(f64, num_str) catch return null;
    if (!std.math.isFinite(factor) or factor <= 0) return null;
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
    pending: ?u64 = null,
    refused: ?Refusal = null,
    editing: bool = false,
    fresh: bool = false,

    pub fn text(self: *const Field) []const u8 {
        return self.chars[0..self.len];
    }

    /// Prepares the field for keyboard input, starting with the current factor.
    pub fn startEditing(self: *Field) void {
        self.refused = null;
        var buf: [max_chars]u8 = undefined;
        const str = format(self.applied, &buf) catch "";
        const count = @min(str.len, max_chars);
        @memcpy(self.chars[0..count], str[0..count]);
        self.len = count;
        self.editing = true;
        self.fresh = true;
    }

    /// Cancels editing and reverts typed text.
    pub fn cancel(self: *Field) void {
        self.len = 0;
        self.refused = null;
        self.editing = false;
        self.fresh = false;
    }

    /// Keeps digits, one dot and the letters of `max`; drops everything else.
    pub fn typed(self: *Field, input: []const u8) void {
        if (self.fresh) {
            self.len = 0;
            self.fresh = false;
        }
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

    pub fn sendSpeed(self: *Field, link: *Link, milli: u64) void {
        self.ask_id = link.send(proto.SetSpeed, .set_speed, .{ .core = self.core, .milli = milli }) catch |err| switch (err) {
            error.TableFull => {
                self.pending = milli;
                return;
            },
            else => {
                self.pending = null;
                self.refused = .session;
                return;
            },
        };
        self.pending = null;
    }

    pub fn retry(self: *Field, link: *Link) void {
        if (self.pending) |milli| {
            self.sendSpeed(link, milli);
        }
    }

    /// Enter sends a valid speed and refuses the rest in the field, Escape
    /// drops what was typed, Backspace drops a character.
    pub fn key(self: *Field, link: *Link, code: u32) !Outcome {
        switch (code) {
            codes.enter, codes.kp_enter => {
                if (self.len == 0) {
                    self.cancel();
                    return .cancel;
                }
                const milli = parse(self.text()) orelse {
                    self.refused = .invalid;
                    self.fresh = false;
                    return .refused;
                };
                self.asked = milli;
                self.editing = false;
                self.fresh = false;
                self.sendSpeed(link, milli);
                return .sent;
            },
            codes.escape => {
                self.cancel();
                return .cancel;
            },
            codes.backspace, codes.delete => {
                if (self.fresh) {
                    self.len = 0;
                    self.fresh = false;
                } else {
                    self.len -|= 1;
                }
                self.refused = null;
            },
            else => {},
        }
        return .typing;
    }

    /// Send a preset speed directly (from the dropdown), clearing any typed text.
    pub fn choose(self: *Field, link: *Link, milli: u64) !Outcome {
        self.asked = milli;
        self.cancel();
        self.sendSpeed(link, milli);
        return .sent;
    }

    /// Takes the session's answer to the last speed sent.
    pub fn observe(self: *Field, arrival: Arrival) void {
        const response = switch (arrival) {
            .response => |response| response,
            .event => return,
        };
        if (response.id != self.ask_id) return;
        self.ask_id = null;
        // A field reopened while the answer was in flight keeps its edit; the
        // answer only settles what the field shows when nothing newer is typed.
        if (response.result == .err) {
            if (!self.editing) self.refused = .session;
            return;
        }
        self.applied = self.asked;
        if (!self.editing) return self.cancel();
        if (self.fresh) self.startEditing();
    }

    /// What the field reads: the typed text while editing or when refused, else the speed in use.
    pub fn shown(self: *const Field, buf: []u8) ![]const u8 {
        if (self.editing or self.len > 0) return std.fmt.bufPrint(buf, "{s}", .{self.text()});
        return format(self.applied, buf);
    }
};
