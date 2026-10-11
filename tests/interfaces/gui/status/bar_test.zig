//! Host tests for the shell's status bar model (RA8EMU-752): the text it
//! reads in each state, and a corpus ELF loaded, stepped and run through a
//! spawned `serve --stdio` child. A fresh run once started is refused (the
//! session wants cont), which the line shows.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const test_paths = @import("test_paths");
const proto = ra8.rpc.session.rpc;
const session_link = gui_app.session_link;
const status_bar = gui_app.status.bar;
const Link = session_link.Link;
const Status = status_bar.Status;

const Env = proto.Client.Env;
const elf_path = "tests/fixtures/fpu/fp_basic.elf";

test "an image is named by its file and the start of its SHA-256" {
    const image = status_bar.Image.of("some/dir/app.elf", "abc");
    try std.testing.expectEqualStrings("app.elf", image.name());
    const want = [_]u8{ 0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea };
    try std.testing.expectEqualSlices(u8, &want, &image.hash);
}

test "the status line reads each connection, image and run state" {
    var buf: [256]u8 = undefined;
    var status: Status = .{};
    try std.testing.expectEqualStrings("connecting | no image", try status.text(.connecting, &buf));
    try std.testing.expectEqualStrings(
        "failed: the session exited | no image",
        try status.text(.{ .failed = .ended }, &buf),
    );
    status.image = status_bar.Image.of("app.elf", "abc");
    status.run = .{ .halted = .{ .address = 0x0800_0100, .reason = .breakpoint } };
    try std.testing.expectEqualStrings(
        "connected (protocol v1) | app.elf ba7816bf8f01cfea | halted at 0x08000100 (breakpoint)",
        try status.text(.{ .connected = .{ .version = 1, .caps = 0 } }, &buf),
    );
    status.run = .running;
    status.refused = .run;
    try std.testing.expectEqualStrings(
        "closed | app.elf ba7816bf8f01cfea | running | the session refused to run",
        try status.text(.closed, &buf),
    );
}

fn pending(status: *const Status) bool {
    return status.load_id != null or status.pc_id != null or status.run == .running;
}

/// Pump the link into the status until nothing is outstanding, for ten seconds.
fn settle(link: *Link, status: *Status) !void {
    const deadline = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() + 10_000;
    while (pending(status)) {
        if (std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() > deadline) return error.Timeout;
        if (link.state != .connected) return error.LinkLost;
        if (link.pump()) |arrival| status.observe(link, arrival) else try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn connect(link: *Link) !void {
    const deadline = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() + 10_000;
    while (link.state == .connecting and std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() < deadline) {
        _ = link.pump();
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(link.state == .connected);
}

test "a corpus ELF loads, steps and runs through a local session, and the status line follows" {
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

    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, elf_path, gpa, .limited(1 << 20));
    defer gpa.free(bytes);
    var status: Status = .{};
    try status.load(&link, elf_path, bytes);
    try settle(&link, &status);
    var buf: [256]u8 = undefined;
    var name_buf: [64]u8 = undefined;
    const image = status_bar.Image.of(elf_path, bytes);
    const named = try std.fmt.bufPrint(&name_buf, "fp_basic.elf {x}", .{&image.hash});
    var line = try status.text(link.state, &buf);
    try std.testing.expect(std.mem.startsWith(u8, line, "connected (protocol v"));
    try std.testing.expect(std.mem.indexOf(u8, line, named) != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "| halted at 0x") != null);
    const reset_pc = status.run.halted.address;

    try status.go(&link, .step, 0);
    try std.testing.expect(std.mem.endsWith(u8, try status.text(link.state, &buf), "| running"));
    try settle(&link, &status);
    line = try status.text(link.state, &buf);
    try std.testing.expect(std.mem.endsWith(u8, line, "(stepped)"));
    try std.testing.expect(status.run.halted.address != reset_pc);

    try status.go(&link, .run, 1000);
    try settle(&link, &status);
    try std.testing.expectEqual(status_bar.Run.unknown, status.run);
    try std.testing.expect(std.mem.endsWith(u8, try status.text(link.state, &buf), "| the session refused to run"));

    try status.go(&link, .cont, 1000);
    try settle(&link, &status);
    try std.testing.expect(status.run == .halted);

    local.end();
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try local.reap());
}

test "a run the shell keeps going in slices reads as running, and its pause as a halt with no reason" {
    var status: status_bar.Status = .{};
    status.image = status_bar.Image.of("app.elf", "abc");
    status.refused = .run;
    status.running();
    try std.testing.expectEqual(status_bar.Run.running, status.run);
    try std.testing.expectEqual(@as(?status_bar.Refusal, null), status.refused);
    status.haltedAt(0x0200_0040);
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "closed | app.elf ba7816bf8f01cfea | halted at 0x02000040",
        try status.text(.closed, &buf),
    );
}
