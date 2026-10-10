//! Tests for src/session/script.zig: lines played into a target, echoed
//! behind the prompt, a bad line reported, and `quit` ending the script.
const std = @import("std");
const ra8 = @import("ra8");
const script = ra8.session.script;
const commands = ra8.session.commands;
const session = ra8.session.session;

/// Answers each command with its name, the way a session answers with
/// what happened; `quit` ends the script.
const Echo = struct {
    pub fn apply(_: *Echo, command: commands.Command, out: anytype) !session.Outcome {
        try out.print("did {s}\n", .{@tagName(command)});
        return if (command == .quit) .quit else .more;
    }
};

test "a script echoes each command, reports a bad line and stops at quit" {
    var target: Echo = .{};
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const text =
        \\# walk the nops
        \\step
        \\
        \\  step   # the second
        \\jump 0
        \\quit
        \\step
    ;
    try std.testing.expectEqual(session.Outcome.quit, try script.play(&target, text, &out.writer, true));
    try std.testing.expectEqualStrings(
        \\(ra8) step
        \\did step
        \\(ra8) step   # the second
        \\did step
        \\(ra8) jump 0
        \\error: UnknownCommand
        \\(ra8) quit
        \\did quit
        \\
    , out.written());
}

test "without echo only the answers are printed, and a script may end without quit" {
    var target: Echo = .{};
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectEqual(session.Outcome.more, try script.play(&target, "step\nstep\n", &out.writer, false));
    try std.testing.expectEqualStrings("did step\ndid step\n", out.written());
}
