//! Tests for src/interfaces/gui/local_session.zig (RA8EMU-1092): the shell's
//! local session is served in-process, greets a link over the loopback and
//! sets its own camera hook.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");

const local_session = gui_app.local_session;
const proto = ra8.rpc.session_rpc;

const image = "tests/fixtures/fpu/fp_basic.elf";

test "the local session greets the shell's client in-process" {
    const gpa = std.testing.allocator;
    var session: local_session.LocalSession = undefined;
    try session.open(gpa, std.testing.io, image);
    defer session.deinit();
    const Env = proto.Client.Env;
    const rx = try gpa.alloc(u8, 2 * Env.max_frame);
    defer gpa.free(rx);
    const tx = try gpa.alloc(u8, Env.max_frame);
    defer gpa.free(tx);
    var client = proto.Client.init(session.transport(), rx, proto.capabilities);
    try client.greet(tx);
    try session.answer();
    const ready = (try client.poll(tx)).?;
    try std.testing.expectEqual(proto.capabilities, ready.ready);
}

test "answering with nothing sent is a no-op" {
    var session: local_session.LocalSession = undefined;
    try session.open(std.testing.allocator, std.testing.io, image);
    defer session.deinit();
    try session.answer();
    try std.testing.expect(session.setup.context.camera != null);
}
