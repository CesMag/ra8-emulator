//! A failed replacement never closes the shell's existing session.
const std = @import("std");
const gui = @import("gui_app");
const ra8 = @import("ra8");

test "missing and malformed startup apps leave a GUI rebuild's old session usable" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "bad.ra8app", .data = "not an app" });
    const bad = try temp.dir.realPathFileAlloc(io, "bad.ra8app", gpa);
    defer gpa.free(bad);
    var session: gui.local_session.LocalSession = undefined;
    try session.open(gpa, io, "tests/fixtures/fpu/fp_basic.elf", null);
    defer session.deinit();
    const original = session.setup;
    const cpu = session.setup.owner.primaryCpu();
    const before = cpu.regs;
    var pick: gui.shell.board_pick.Pick = .{ .allocator = gpa };
    var rebuild: gui.shell.rebuild.Rebuild = .{
        .allocator = gpa,
        .io = io,
        .image = "tests/fixtures/fpu/fp_basic.elf",
        .apps = &.{"missing-rebuild-app.ra8app"},
        .session = &session,
        .shell = undefined,
        .hosted = undefined,
        .link = undefined,
        .worker = undefined,
        .pick = &pick,
    };
    try std.testing.expectError(error.FileNotFound, rebuild.apply(ra8.board.profile.ek_ra8d2));
    try std.testing.expectEqual(original, session.setup);
    try std.testing.expectEqualDeep(before, cpu.regs);
    rebuild.apps = &.{bad};
    try std.testing.expectError(error.ShortImage, rebuild.apply(ra8.board.profile.ek_ra8d2));
    try std.testing.expectEqual(original, session.setup);
    _ = try session.setup.owner.session().run(.cpu0, .step);
    try std.testing.expect(cpu.slots > 0);
}

test "a successful rebuild rebinds the hosted context and retires old GDB sessions" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const helpers = @import("../../rpc/host_listener_helpers.zig");
    const home = try helpers.tempHome(gpa);
    defer {
        std.Io.Dir.cwd().deleteTree(io, home) catch {};
        gpa.free(home);
    }
    var env = try helpers.envWithHome(gpa, home);
    defer env.deinit();
    var rig: @import("../local_rig.zig").Rig = undefined;
    const image = "tests/fixtures/fpu/fp_basic.elf";
    try rig.open(image);
    defer rig.deinit();
    var shell: gui.shell.loop.Shell = .init(gpa, try gui.pane_layout.twoCore(gpa));
    defer shell.deinit();
    var hosted: ?gui.shell.hosted.Hosted = .{
        .listener = try ra8.rpc.host_listener.Listener.bind(gpa, io, &env),
        .context = &rig.session.setup.context,
        .window = undefined,
        .tx = try gpa.alloc(u8, ra8.rpc.session.rpc.Client.Env.max_frame),
        .gpa = gpa,
    };
    defer hosted.?.deinit();
    hosted.?.announce(image, rig.session.setup.owner.session());
    try std.testing.expectEqual(@as(usize, 1), hosted.?.listener.gdb.items.len);
    const Connection = ra8.rpc.socket_transport.Connection;
    const proto = ra8.rpc.session.rpc;
    const Peer = @import("../../cli/serve_peer.zig").Peer;
    var connection = switch (hosted.?.listener.address) {
        .unix => |path| try Connection.unix(io, path),
        .tcp => |ip| try Connection.tcp(io, ip),
    };
    defer connection.close();
    const peer = try Peer.init(gpa, connection.transport());
    defer peer.deinit();
    try peer.client.greet(peer.tx);
    _ = try helpers.next(peer, &hosted.?.listener, hosted.?.context, hosted.?.tx);
    _ = try helpers.call(peer, &hosted.?.listener, hosted.?.context, hosted.?.tx, proto.Ack, proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .uart });
    try std.testing.expect(hosted.?.listener.client.?.context.uart_feed != null);
    const old = rig.session.setup;
    var pick: gui.shell.board_pick.Pick = .{ .allocator = gpa };
    var rebuild: gui.shell.rebuild.Rebuild = .{ .allocator = gpa, .io = io, .image = image, .apps = &.{}, .session = &rig.session, .shell = &shell, .hosted = &hosted, .link = &rig.link, .worker = &rig.worker, .pick = &pick };
    try rebuild.apply(ra8.board.profile.ek_ra8d2);
    try std.testing.expect(old != rig.session.setup);
    try std.testing.expectEqual(&rig.session.setup.context, hosted.?.context);
    try std.testing.expect(hosted.?.context.transport_async);
    try std.testing.expect(hosted.?.listener.client == null);
    try std.testing.expectEqual(@as(usize, 1), hosted.?.listener.gdb.items.len);
    try std.testing.expectEqual(rig.session.setup.owner.session(), hosted.?.listener.gdb.items[0].live.?);
    _ = try rig.session.setup.owner.session().run(.cpu0, .step);
    try std.testing.expect(rig.session.setup.owner.primaryCpu().slots > 0);
}
