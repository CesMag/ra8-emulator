//! Over-the-wire test for the session's input method (RA8EMU-810): a
//! spawned `serve --stdio` session takes a button press and a panel tap
//! through session_link and accepts both onto its input script, and an
//! unknown button comes back as bad_args.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const test_paths = @import("test_paths");
const proto = ra8.rpc.session.rpc;
const session_link = gui_app.session_link;
const Link = session_link.Link;
const Env = proto.Client.Env;

const elf_path = "tests/fixtures/fpu/fp_basic.elf";

fn connect(link: *Link) !void {
    const deadline = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() + 10_000;
    while (link.state == .connecting and std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() < deadline) {
        _ = link.pump();
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(link.state == .connected);
}

/// Send one input request and wait for its answer, skipping anything else
/// that arrives.
fn schedule(link: *Link, args: proto.ScheduleInput) !Env.Result {
    const id = try link.send(proto.ScheduleInput, .input, args);
    const deadline = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() + 10_000;
    while (std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() < deadline) {
        if (link.state != .connected) return error.LinkLost;
        const arrival = link.pump() orelse {
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
            continue;
        };
        switch (arrival) {
            .response => |response| if (response.id == id) return response.result,
            .event => {},
        }
    }
    return error.Timeout;
}

fn accepted(result: Env.Result) !void {
    const ok = switch (result) {
        .ok => |bytes| bytes,
        .err => return error.Refused,
    };
    const answer = try proto.decode(proto.Ack, ok);
    try std.testing.expectEqual(@as(u8, 1), answer.accepted);
}

test "a served session accepts a button press and a tap over the wire" {
    const gpa = std.testing.allocator;
    var local: session_link.Local = undefined;
    try local.spawn(std.testing.io, test_paths.emulator, elf_path);
    errdefer local.child.kill(std.testing.io);
    const rx = try gpa.alloc(u8, 2 * Env.max_frame);
    defer gpa.free(rx);
    const tx = try gpa.alloc(u8, Env.max_frame);
    defer gpa.free(tx);
    var link: Link = undefined;
    link.open(local.transport(), rx, tx);
    try connect(&link);
    const caps = link.state.connected.caps;
    try std.testing.expect(caps & (1 << 8) != 0);

    try accepted(try schedule(&link, .{ .core = .cpu0, .at_ns = 1_000_000, .kind = .button, .button = 1 }));
    try accepted(try schedule(&link, .{ .core = .cpu0, .at_ns = 2_000_000, .kind = .tap, .x = 120, .y = 300 }));
    const unknown = try schedule(&link, .{ .core = .cpu0, .at_ns = 3_000_000, .kind = .button, .button = 2 });
    try std.testing.expect(unknown == .err);
    try std.testing.expect(unknown.err == .bad_args);

    local.end();
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try local.reap());
}
