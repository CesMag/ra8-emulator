//! The live stdout sink for `--console`, separate from the end-of-run report,
//! and the tap `--until` reads finished lines from.
const std = @import("std");
const sci_line = @import("ra8_chip").periph.sci_line;
const until = @import("ra8_chip").core.until;
const sci_reply = @import("ra8_chip").periph.sci_reply;

/// Where each finished console line goes: stdout when `--console` asked
/// for it, and the `--until` wait when one is set.
pub const Tap = struct {
    /// The io `--console` echoes stdout with; null when it echoes nothing.
    echo: ?std.Io = null,
    wait: ?until.Until = null,
    /// The `--console-reply` that watches for its prompt (RA8EMU-626).
    reply: ?*sci_reply.Reply = null,

    /// Whether the line needs a sink at all.
    pub fn wanted(self: Tap) bool {
        return self.echo != null or self.wait != null or self.reply != null;
    }

    /// The `--until` wait the run loop checks, held here so it lives as
    /// long as the sink that feeds it.
    pub fn waiting(self: *Tap) ?*until.Until {
        return if (self.wait) |*one| one else null;
    }
};

/// Hang the tap on the console line. The tap has to outlive the run.
pub fn configure(line: *sci_line.Line, tap: *Tap) void {
    if (tap.wanted()) line.setSink(.{ .context = tap, .writeFn = tapLine });
}

/// Hand one finished line to the tap.
pub fn tapLine(context: ?*anyopaque, text: []const u8) anyerror!void {
    const tap: *Tap = @ptrCast(@alignCast(context.?));
    if (tap.waiting()) |wait| wait.line(text);
    if (tap.reply) |reply| reply.line(text);
    if (tap.echo) |io| try writeLine(io, text);
}

/// Keep transcript lines visibly distinct from report sections.
/// The line is flushed whole, so it never interleaves with a report line.
fn writeLine(io: std.Io, text: []const u8) anyerror!void {
    var buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const out = &stdout.interface;
    try out.writeAll("console> ");
    try out.writeAll(text);
    try out.writeAll("\n");
    try out.flush();
}
