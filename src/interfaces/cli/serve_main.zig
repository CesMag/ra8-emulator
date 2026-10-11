//! `ra8_emulator serve` (RA8EMU-737, RA8EMU-736): a headless session server.
//!
//! It opens the ELF through served_setup and answers session RPC
//! frames on stdin/stdout (--stdio) or on one socket client at a time
//! (--listen). Frames are the only thing written to stdout; complaints go
//! to stderr.
const std = @import("std");
const served_setup = @import("ra8_rpc").served_setup;
const loop = @import("serve_loop.zig");
const listen = @import("serve_listen.zig");

pub const usage =
    \\usage: ra8_emulator serve [--profile-folded] --stdio <firmware.elf>
    \\       ra8_emulator serve [--profile-folded] --listen unix:PATH|tcp:[HOST]:PORT <firmware.elf>
    \\       --profile-folded samples CPU0's call stacks for `ctl folded`
    \\
;

const Where = union(enum) { stdio, listen: listen.Spec };
const Asked = struct { where: Where, elf: []const u8, folded: bool = false };

/// Samples taken one every this many CPU0 instructions under --profile-folded.
pub const fold_every: u32 = 1000;

/// The transport and image `argv` asks for, or null for a malformed line.
pub fn parse(argv: []const []const u8) ?Asked {
    if (argv.len > 2 and std.mem.eql(u8, argv[2], "--profile-folded")) {
        // Drop the flag; the transport then sits at argv[2] as before.
        var asked = parseWhere(argv[1..]) orelse return null;
        asked.folded = true;
        return asked;
    }
    return parseWhere(argv);
}

fn parseWhere(argv: []const []const u8) ?Asked {
    if (argv.len == 4 and std.mem.eql(u8, argv[2], "--stdio")) return .{ .where = .stdio, .elf = argv[3] };
    if (argv.len != 5 or !std.mem.eql(u8, argv[2], "--listen")) return null;
    const spec = listen.Spec.parse(argv[3]) catch return null;
    return .{ .where = .{ .listen = spec }, .elf = argv[4] };
}

/// Serve `argv` (`ra8_emulator serve ...`) and return the exit code.
pub fn run(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !u8 {
    const asked = parse(argv) orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    var setup: served_setup.Served = undefined;
    setup.open(allocator, io, asked.elf) catch |err| {
        std.debug.print("serve: cannot open {s}: {s}\n", .{ asked.elf, @errorName(err) });
        return 1;
    };
    defer setup.deinit();
    if (asked.folded) setup.sampleStacks(fold_every) catch |err| {
        std.debug.print("serve: cannot sample stacks: {s}\n", .{@errorName(err)});
        return 1;
    };
    const buffers: loop.Buffers = .{ .rx = setup.rx, .tx = setup.tx };
    const context = &setup.context;
    const done = switch (asked.where) {
        .stdio => loop.answerStdio(context, buffers),
        .listen => |spec| listen.serve(io, spec, context, buffers),
    };
    done catch |err| {
        std.debug.print("serve: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}
