//! Host listener discovery, served RPC, GDB and reconnect tests (RA8EMU-1156).
//! They use the same Served context as the primary connection and real host sockets.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const serve_peer = @import("../cli/serve_peer.zig");
const slow_peer = @import("slow_peer.zig");
const listener_mod = ra8.rpc.host_listener;
const Connection = ra8.rpc.socket_transport.Connection;
const served_setup = ra8.rpc.served_setup;
const proto = ra8.rpc.session.rpc;

const image = serve_peer.image_path;
const Env = proto.Client.Env;

/// A fresh home under /tmp for one test.
const tempHome = helpers.tempHome;
const envWithHome = helpers.envWithHome;
test "the discovery file lists the rpc address and the sessions" {
    const gpa = std.testing.allocator;
    const home = try tempHome(gpa);
    defer {
        std.Io.Dir.cwd().deleteTree(std.testing.io, home) catch {};
        gpa.free(home);
    }
    var env = try envWithHome(gpa, home);
    defer env.deinit();
    var bound = try listener_mod.Listener.bind(gpa, std.testing.io, &env);

    const port = try bound.addGdb("/some/image.elf", null);
    try bound.announce();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}", .{bound.discovery_path});
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(4096));
    defer gpa.free(text);

    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, text, "\n"), '\n');
    const rpc_line = lines.next().?;
    const spec = try cli_app.serve.listen.Spec.parse(rpc_line["rpc ".len..]);
    switch (bound.address) {
        .unix => |path_name| try std.testing.expectEqualStrings(path_name, spec.unix),
        .tcp => |address| {
            try std.testing.expect(spec.tcp.eql(&address));
            try std.testing.expect(bound.socket_path == null);
        },
    }
    var port_buf: [32]u8 = undefined;
    const port_line = try std.fmt.bufPrint(&port_buf, "session {d} /some/image.elf", .{port});
    try std.testing.expectEqualStrings(port_line, lines.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), lines.next());

    bound.deinit();
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(16)));
}

test "a client over the socket is served on the opened session" {
    const gpa = std.testing.allocator;
    const home = try tempHome(gpa);
    defer {
        std.Io.Dir.cwd().deleteTree(std.testing.io, home) catch {};
        gpa.free(home);
    }
    var env = try envWithHome(gpa, home);
    defer env.deinit();
    var opened: served_setup.Served = undefined;
    try opened.open(gpa, std.testing.io, image, null, null);
    defer opened.deinit();
    var bound = try listener_mod.Listener.bind(gpa, std.testing.io, &env);
    defer bound.deinit();

    const tx = try gpa.alloc(u8, Env.max_frame);
    defer gpa.free(tx);
    var connection = try connect(bound.address);
    defer connection.close();
    const peer = try serve_peer.Peer.init(gpa, connection.transport());
    defer peer.deinit();

    try peer.client.greet(peer.tx);
    try bound.answer(&opened.context, tx);
    try std.testing.expectEqual(proto.capabilities, (try next(peer, &bound, &opened.context, tx)).ready);
    try loadAndRead(peer, &bound, &opened.context, tx);
}

test "a client's subscriptions stay off the primary connection' context" {
    const gpa = std.testing.allocator;
    const home = try tempHome(gpa);
    defer {
        std.Io.Dir.cwd().deleteTree(std.testing.io, home) catch {};
        gpa.free(home);
    }
    var env = try envWithHome(gpa, home);
    defer env.deinit();
    var opened: served_setup.Served = undefined;
    try opened.open(gpa, std.testing.io, image, null, null);
    defer opened.deinit();
    var bound = try listener_mod.Listener.bind(gpa, std.testing.io, &env);
    defer bound.deinit();

    const tx = try gpa.alloc(u8, Env.max_frame);
    defer gpa.free(tx);
    var connection = try connect(bound.address);
    const peer = try serve_peer.Peer.init(gpa, connection.transport());
    defer peer.deinit();
    try peer.client.greet(peer.tx);
    try bound.answer(&opened.context, tx);
    _ = try next(peer, &bound, &opened.context, tx);

    // The client subscribes to the uart topic over the wire and gets its
    // own feed; the primary connection' context keeps none and no topics (RA8EMU-1196).
    _ = try call(peer, &bound, &opened.context, tx, proto.Ack, proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .uart });
    try std.testing.expect(bound.client.?.context.uart_feed != null);
    try std.testing.expectEqual(@as(?usize, null), opened.context.uart_feed);
    try std.testing.expectEqual(@as(u8, 0), opened.context.topics[0]);

    // Hanging up releases the client's feed; the primary connection' context is untouched.
    connection.close();
    try bound.answer(&opened.context, tx);
    try std.testing.expect(bound.client == null);
    try std.testing.expectEqual(@as(?usize, null), opened.context.uart_feed);
}

test "a hung-up client is dropped and the next one is taken" {
    const gpa = std.testing.allocator;
    const home = try tempHome(gpa);
    defer {
        std.Io.Dir.cwd().deleteTree(std.testing.io, home) catch {};
        gpa.free(home);
    }
    var env = try envWithHome(gpa, home);
    defer env.deinit();
    var opened: served_setup.Served = undefined;
    try opened.open(gpa, std.testing.io, image, null, null);
    defer opened.deinit();
    var bound = try listener_mod.Listener.bind(gpa, std.testing.io, &env);
    defer bound.deinit();

    const tx = try gpa.alloc(u8, Env.max_frame);
    defer gpa.free(tx);
    var first = try connect(bound.address);
    try bound.answer(&opened.context, tx);
    try std.testing.expect(bound.client != null);
    first.close();
    try bound.answer(&opened.context, tx);
    try std.testing.expect(bound.client == null);

    var second = try connect(bound.address);
    defer second.close();
    try bound.answer(&opened.context, tx);
    try std.testing.expect(bound.client != null);
}

test "a gdb client breaks, continues, hits it and reads registers" {
    const gpa = std.testing.allocator;
    const home = try tempHome(gpa);
    defer {
        std.Io.Dir.cwd().deleteTree(std.testing.io, home) catch {};
        gpa.free(home);
    }
    var env = try envWithHome(gpa, home);
    defer env.deinit();
    var opened: served_setup.Served = undefined;
    try opened.open(gpa, std.testing.io, image, null, null);
    defer opened.deinit();
    var bound = try listener_mod.Listener.bind(gpa, std.testing.io, &env);
    defer bound.deinit();
    const port = try bound.addGdb(image, opened.context.session);

    const tx = try gpa.alloc(u8, Env.max_frame);
    defer gpa.free(tx);
    var connection = try connect(bound.address);
    defer connection.close();
    const peer = try serve_peer.Peer.init(gpa, connection.transport());
    defer peer.deinit();
    try peer.client.greet(peer.tx);
    try bound.answer(&opened.context, tx);
    try std.testing.expectEqual(proto.capabilities, (try next(peer, &bound, &opened.context, tx)).ready);

    // Load, run a budget and pause, so the core sits at a known pc.
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, image, peer.gpa, .limited(1 << 20));
    defer peer.gpa.free(bytes);
    _ = try call(peer, &bound, &opened.context, tx, proto.Ack, proto.Load, .load, .{ .core = .cpu0, .image = bytes });
    _ = try call(peer, &bound, &opened.context, tx, proto.Ack, proto.Run, .run, .{ .core = .cpu0, .mode = .cont, .budget = 1000 });
    _ = try call(peer, &bound, &opened.context, tx, proto.Ack, proto.CoreOnly, .pause, .{ .core = .cpu0 });
    const pc0 = try call(peer, &bound, &opened.context, tx, proto.U32, proto.ReadRegister, .read_register, .{ .core = .cpu0, .register = .pc });
    try std.testing.expect(pc0.value != 0);

    var gdb: Gdb = undefined;
    try gdb.init(port);
    defer gdb.deinit();

    // pc() sends a register read and parses the reply in target order.
    try std.testing.expectEqual(pc0.value, try gdb.pc(&bound));

    // Continuing from this breakpoint delivers the hit's stop reply.
    var point: [32]u8 = undefined;
    const where = try std.fmt.bufPrint(&point, "Z0,{x},1", .{pc0.value});
    try gdb.send(where);
    try std.testing.expectEqualStrings("OK", try gdb.reply(&bound));
    try gdb.send("c");
    const stop = try gdb.reply(&bound);
    try std.testing.expect(stop.len > 0 and (stop[0] == 'T' or stop[0] == 'S'));
    try std.testing.expectEqual(pc0.value, try gdb.pc(&bound));

    // The IDE's reset halt reboots from the ELF and pauses at its vector.
    const halt = try monitorHex(gpa, "reset halt");
    defer gpa.free(halt);
    try gdb.send(halt);
    try std.testing.expectEqualStrings("OK", try gdb.reply(&bound));
    const pc1 = try gdb.pc(&bound);
    try std.testing.expect(pc1 != pc0.value);
    const reload = try monitorHex(gpa, "reload");
    defer gpa.free(reload);
    try gdb.send(reload);
    try std.testing.expectEqualStrings("OK", try gdb.reply(&bound));
    try std.testing.expectEqual(pc1, try gdb.pc(&bound));

    // A monitor reply to a peer that stopped reading drops the client.
    const host = bound.gdb.items[0];
    try slow_peer.block(host.client.?.stream);
    try gdb.send("qRcmd,");
    // The drop is a matter of the host noticing the stopped reader,
    // not of the clock: two validation runs at once have shown two
    // seconds to be shorter than a loaded runner takes, so the check
    // takes the same ten seconds the queued-reply loop below does.
    const deadline = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() + 10_000;
    while (host.client != null and std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() < deadline) bound.pumpGdb();
    try std.testing.expect(host.client == null);
}
const helpers = @import("host_listener_helpers.zig");
const Gdb = helpers.Gdb;
const monitorHex = helpers.monitorHex;
const next = helpers.next;
const call = helpers.call;
const loadAndRead = helpers.loadAndRead;

fn connect(address: listener_mod.Address) !Connection {
    return switch (address) {
        .unix => |path| Connection.unix(std.testing.io, path),
        .tcp => |ip| Connection.tcp(std.testing.io, ip),
    };
}

test "an async advance queues over the socket and completes on the transport topic" {
    const gpa = std.testing.allocator;
    const home = try tempHome(gpa);
    defer {
        std.Io.Dir.cwd().deleteTree(std.testing.io, home) catch {};
        gpa.free(home);
    }
    var env = try envWithHome(gpa, home);
    defer env.deinit();
    var opened: served_setup.Served = undefined;
    try opened.open(gpa, std.testing.io, image, null, null);
    defer opened.deinit();
    // The daemon can bind the queued advance contract;
    // the test mirrors it so the listener's client sees bit 15.
    opened.context.transport_async = true;
    var bound = try listener_mod.Listener.bind(gpa, std.testing.io, &env);
    defer bound.deinit();

    const tx = try gpa.alloc(u8, Env.max_frame);
    defer gpa.free(tx);
    var connection = try connect(bound.address);
    defer connection.close();
    const peer = try serve_peer.Peer.init(gpa, connection.transport());
    defer peer.deinit();
    try peer.client.greet(peer.tx);
    try bound.answer(&opened.context, tx);
    const ready = try next(peer, &bound, &opened.context, tx);
    try std.testing.expect(ready.ready & proto.transport_cap != 0);

    try loadAndRead(peer, &bound, &opened.context, tx);
    _ = try call(peer, &bound, &opened.context, tx, proto.Ack, proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .transport });

    // The queued reply arrives without the connection blocking on the job,
    // and the completion lands on the transport topic: a TransportEvent with
    // finished = 1 carrying the queued advance's own span. The first pump
    // can finish the job before the reply is even read, so the drain
    // collects events from the queue call on and never swallows one.
    _ = try peer.client.call(proto.Advance, @backingInt(proto.Method.advance_async), .{ .core = .cpu0, .ns = 50_000_000 }, 0, peer.tx);
    var queued: ?proto.AdvanceQueued = null;
    var finished: ?proto.TransportEvent = null;
    const deadline = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() + 10_000;
    while ((queued == null or finished == null) and std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() < deadline) {
        switch (try next(peer, &bound, &opened.context, tx)) {
            .response => |response| queued = switch (response.result) {
                .ok => |bytes| try proto.decode(proto.AdvanceQueued, bytes),
                .err => return error.Refused,
            },
            .event => |event| {
                if (event.topic != @backingInt(proto.Topic.transport)) continue;
                const report = try proto.decode(proto.TransportEvent, event.payload);
                if (report.finished != 1) continue;
                try std.testing.expectEqual(@as(u8, @backingInt(proto.Core.cpu0)), @backingInt(report.core));
                finished = report;
            },
            else => {},
        }
    }
    const span = queued orelse return error.NoQueuedReply;
    try std.testing.expectEqual(@as(u64, 50_000_000), span.target_ns - span.from_ns);
    const done = finished orelse return error.NoFinishedEvent;
    try std.testing.expectEqual(span.from_ns, done.from_ns);
    try std.testing.expectEqual(span.target_ns, done.target_ns);
    try std.testing.expect(done.to_ns >= span.target_ns);
}
