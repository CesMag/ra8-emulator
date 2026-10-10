//! The debugger's front end: `--debug-script FILE`, `--debug` and
//! `--gdb PORT`.
//!
//! ```
//! ra8_emulator firmware.elf [--cpu1 IMAGE.elf] --debug-script session.gdb
//! ra8_emulator firmware.elf [--cpu1 IMAGE.elf] --debug
//! ra8_emulator firmware.elf [--cpu1 IMAGE.elf] --gdb 3333
//! ```
//!
//! `--gdb` listens on 127.0.0.1 for one gdb connection and serves the same
//! session over the remote protocol, each core a thread, until gdb detaches.
//!
//! The first plays a script and prints its transcript, each command echoed
//! behind the prompt. The second reads commands from the terminal until
//! `quit` or end of input. Both load the image onto the board, reset out of
//! its vector table, and hand the core to a debugger session; `run` starts
//! from the reset handler, under the run loop with the same time base,
//! NVIC, board tick and reset handling an ordinary run has. With `--cpu1`, the second core comes up on the
//! same board from its own image, the way an ordinary run brings it up,
//! and `core 1` selects it. Either flag takes over the whole invocation, so
//! neither mixes with the run-and-report flags.
//!
//! The session steps the core on its own, without the run loop that drives
//! SysTick and the interrupt controller, so firmware that waits on an
//! interrupt waits forever here. Bringing the run loop under the session is
//! the next step for this front end.
const std = @import("std");
const cli = @import("cli.zig");
const cpu_choice = @import("ra8_chip").core.cpu.choice;
const zig_debug_front = @import("zig_debug_front.zig");
const script = @import("../../session/script.zig");

pub const usage =
    \\usage: ra8_emulator <firmware.elf> [--cpu1 IMAGE.elf] --debug-script FILE
    \\       ra8_emulator <firmware.elf> [--cpu1 IMAGE.elf] --debug
    \\       ra8_emulator <firmware.elf> [--cpu1 IMAGE.elf] --gdb PORT
    \\       --cpu zig may go anywhere
    \\
;

pub const limits = struct {
    /// The largest image or script read in. Firmware images here run to a
    /// few megabytes with their debug sections.
    pub const max_file: usize = 64 * 1024 * 1024;
    /// The longest command line read from the terminal.
    pub const max_line: usize = 1024;
};

pub const flags = struct {
    pub const script = "--debug-script";
    pub const interactive = "--debug";
    pub const gdb = "--gdb";
    pub const cpu1 = "--cpu1";
    pub const cpu = "--cpu";
};

pub const Mode = union(enum) {
    script: []const u8,
    interactive,
    /// The local TCP port gdb connects to.
    gdb: u16,
};

/// What the debugger command line asked for.
pub const Request = struct {
    mode: Mode,
    /// The image the second core runs, when one was named.
    cpu1: ?[]const u8 = null,
    /// The image CPU0 runs.
    image: []const u8 = "",
    /// Which CPU the session drives (`--cpu`, anywhere on the line).
    cpu: cpu_choice.Choice = .zig,
};

/// The most arguments a debugger command line carries.
const max_args = 16;

/// The debugger request the command line makes, or null when it asks for
/// an ordinary run. A malformed debugger command line is reported as such
/// rather than handed to the ordinary parser.
pub fn wanted(argv: []const []const u8) ?error{BadUsage}!Request {
    for (argv) |arg| {
        if (isDebugFlag(arg)) break;
    } else return null;
    var rest_buffer: [max_args][]const u8 = undefined;
    var rest: std.ArrayList([]const u8) = .initBuffer(&rest_buffer);
    var cpu: ?cpu_choice.Choice = .zig;
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        if (std.mem.eql(u8, argv[index], flags.cpu) and index + 1 < argv.len) {
            cpu = cpu_choice.Choice.parse(argv[index + 1]);
            index += 1;
        } else rest.appendBounded(argv[index]) catch return error.BadUsage;
    }
    var request = (plain(rest.items) orelse return null) catch |err| return err;
    request.cpu = cpu orelse return error.BadUsage;
    return request;
}

/// `wanted` with `--cpu` taken out.
fn plain(argv: []const []const u8) ?error{BadUsage}!Request {
    const at = for (argv, 0..) |arg, index| {
        if (isDebugFlag(arg)) break index;
    } else return null;
    var request = Request{ .mode = .interactive };
    var index: usize = 2;
    if (index + 1 < argv.len and std.mem.eql(u8, argv[index], flags.cpu1)) {
        request.cpu1 = argv[index + 1];
        index += 2;
    }
    if (index != at) return error.BadUsage;
    request.image = argv[1];
    if (std.mem.eql(u8, argv[at], flags.interactive)) {
        return if (argv.len == at + 1) request else error.BadUsage;
    }
    if (argv.len != at + 2) return error.BadUsage;
    if (std.mem.eql(u8, argv[at], flags.gdb)) {
        const port = std.fmt.parseInt(u16, argv[at + 1], 10) catch return error.BadUsage;
        request.mode = .{ .gdb = port };
        return request;
    }
    request.mode = .{ .script = argv[at + 1] };
    return request;
}

fn isDebugFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, flags.script) or std.mem.eql(u8, arg, flags.interactive) or std.mem.eql(u8, arg, flags.gdb);
}

/// A command line the run parser refused. The debugger flags are not run
/// flags, so a debugger invocation lands here: run it, print the
/// debugger's usage when it is malformed, or the run usage when it was
/// never a debugger invocation at all.
pub fn refused(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !u8 {
    const asked = wanted(argv) orelse {
        std.debug.print("{s}", .{cli.usage});
        return 2;
    };
    const request = asked catch {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    return run(allocator, io, argv, request);
}

/// Hand the image path to the public harness-backed Zig debugger.
pub fn run(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, request: Request) !u8 {
    _ = argv;
    // Unbuffered, so the prompt shows before the read that follows it.
    var stdout = std.Io.File.stdout().writerStreaming(io, &.{});
    return zig_debug_front.run(allocator, io, request, &stdout.interface);
}

/// Prompt, read a line, apply it, until `quit` or the end of input.
pub fn converse(io: std.Io, target: anytype, out: anytype) !void {
    var buffer: [limits.max_line]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &buffer);
    const input = &stdin.interface;
    while (true) {
        try out.print("{s}", .{script.prompt});
        const line = input.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                _ = try input.discardDelimiterInclusive('\n');
                try out.print("error: LineTooLong\n", .{});
                continue;
            },
            else => return err,
        } orelse return out.print("\n", .{});
        if (try script.one(target, line, out, false) == .quit) return;
    }
}
