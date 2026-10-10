//! A console line typed back when the firmware prints a prompt.
//!
//! `--console-reply PROMPT=LINE` stands in for the person at the bench
//! terminal: the first finished console line that carries PROMPT makes LINE
//! (and a newline) due, and the next board boundary queues it on the console
//! SCI's RX. Typing it only after the prompt matters: a firmware that drains
//! its RX before it asks (ra8_net_provision's "READY v1") would otherwise
//! throw an early answer away (RA8EMU-626).
const std = @import("std");
const sci = @import("sci.zig");

pub const Error = error{BadReply};

pub const Reply = struct {
    prompt: []const u8 = "",
    text: []const u8 = "",
    due: bool = false,
    sent: bool = false,

    /// PROMPT=LINE, split on the first '='. An empty prompt is refused.
    pub fn parse(spec: []const u8) Error!Reply {
        const eq = std.mem.indexOfScalar(u8, spec, '=') orelse return error.BadReply;
        if (eq == 0) return error.BadReply;
        return .{ .prompt = spec[0..eq], .text = spec[eq + 1 ..] };
    }

    /// Whether a reply was asked for at all.
    pub fn armed(self: Reply) bool {
        return self.prompt.len != 0;
    }

    /// Notes one finished console line; the first carrying the prompt makes
    /// the reply due. The reply is typed once.
    pub fn line(self: *Reply, text: []const u8) void {
        if (!self.armed() or self.sent or self.due) return;
        if (std.mem.indexOf(u8, text, self.prompt) != null) self.due = true;
    }

    /// Queues the due reply and its newline on the console SCI's RX.
    pub fn poll(self: *Reply, unit: *sci.Sci) void {
        if (!self.due) return;
        unit.feed(sci.console_channel, self.text);
        unit.feed(sci.console_channel, "\n");
        self.due = false;
        self.sent = true;
    }
};
