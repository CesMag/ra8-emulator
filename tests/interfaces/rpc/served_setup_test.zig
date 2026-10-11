//! Tests for src/interfaces/rpc/served_setup.zig (RA8EMU-1093): an opened
//! image's server context answers a greeting over an in-memory loopback,
//! its map, stack and rtc hooks are filled in, and set_camera_source opens
//! the source from the host and installs it (RA8EMU-1114).
const std = @import("std");
const ra8 = @import("ra8");

const setup = ra8.rpc.served_setup;
const served = ra8.rpc.session.server;
const proto = ra8.rpc.session.rpc;
const camera = ra8.rpc.session.camera;
const rpc = served.rpc_lib;

const image = "tests/fixtures/fpu/fp_basic.elf";

test "an opened image greets a client over a loopback" {
    const gpa = std.testing.allocator;
    var opened: setup.Served = undefined;
    try opened.open(gpa, std.testing.io, image);
    defer opened.deinit();
    const Env = proto.Client.Env;
    const pipes = [2][]u8{ try gpa.alloc(u8, 2 * Env.max_frame), try gpa.alloc(u8, 2 * Env.max_frame) };
    defer for (pipes) |pipe| gpa.free(pipe);
    const client_rx = try gpa.alloc(u8, 2 * Env.max_frame);
    defer gpa.free(client_rx);
    var loop = rpc.Loopback.init(pipes[0], pipes[1]);
    var client = proto.Client.init(loop.a(), client_rx, proto.capabilities);
    var host = served.Host.init(loop.b(), opened.rx, &opened.context);
    try client.greet(opened.tx);
    try std.testing.expectEqual(rpc.Step.greeted, try host.poll(opened.tx));
    const ready = (try client.poll(opened.tx)).?;
    try std.testing.expectEqual(proto.capabilities, ready.ready);
}

test "the map, stack, rtc, parts and camera hooks are set" {
    var opened: setup.Served = undefined;
    try opened.open(std.testing.allocator, std.testing.io, image);
    defer opened.deinit();
    const context = &opened.context;
    try std.testing.expect(context.listing != null);
    try std.testing.expect(context.clock != null);
    try std.testing.expect(context.camera != null);
    const mapping = context.mapping.?;
    var out: [8192]u8 = undefined;
    const text = try mapping.mapFn(mapping.context, 0, false, &out);
    try std.testing.expect(std.mem.indexOf(u8, text, "MRAM     0x") != null);
    const json = try mapping.mapFn(mapping.context, 0, true, &out);
    try std.testing.expect(std.mem.startsWith(u8, json, "{\"regions\":"));
    try std.testing.expectError(error.NoImage, mapping.mapFn(mapping.context, 1, false, &out));
}

/// A two-pixel picture on disk for the camera to open.
fn picture(dir: std.Io.Dir, name: []const u8) !void {
    try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = "P6\n2 1\n255\n" ++ "\x10\x20\x30\x40\x50\x60" });
}

test "set_camera_source opens the source from the host and installs it on the board" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try picture(temp.dir, "still.ppm");
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const path = try std.fmt.allocPrint(gpa, "image:{s}/still.ppm", .{root});
    defer gpa.free(path);

    var opened: setup.Served = undefined;
    try opened.open(gpa, std.testing.io, image);
    defer opened.deinit();
    const source = &opened.owner.board().capture.source;
    const before = source.label;
    const taken = camera.setCameraSource(&opened.context, .{ .text = path });
    try std.testing.expectEqual(@as(u8, 1), taken.ok.accepted);
    try std.testing.expectEqualStrings("still image", source.label);
    try std.testing.expect(!std.mem.eql(u8, before, source.label));

    const back = camera.setCameraSource(&opened.context, .{ .text = "gradient" });
    try std.testing.expectEqual(@as(u8, 1), back.ok.accepted);
    try std.testing.expectEqualStrings(before, source.label);
}

test "a source that will not open is refused and the old one stays" {
    var opened: setup.Served = undefined;
    try opened.open(std.testing.allocator, std.testing.io, image);
    defer opened.deinit();
    const source = &opened.owner.board().capture.source;
    const before = source.label;
    const refused = camera.setCameraSource(&opened.context, .{ .text = "image:/nonexistent/ra8/still.ppm" });
    try std.testing.expect(refused == .err);
    try std.testing.expectEqualStrings(before, source.label);
}
