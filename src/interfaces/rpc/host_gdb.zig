//! One session's gdb port while the app hosts it (RA8EMU-1156): a loopback
//! TCP listener per session, listed in the discovery file, and one gdb
//! client served a frame at a time so the daemon keeps serving between
//! packets. Reads are answered at once; a continue runs one budget per
//! pump and its stop reply goes out when the run ends (rsp_zig's pump
//! mode). Nothing here blocks: every step peeks first.
const std = @import("std");
const sock_ready = @import("ra8_host").sock.ready;
const rsp = @import("ra8_gdb").rsp;
const session_api = @import("ra8_session").api;

/// The largest packet the stub reads, in bytes, as qSupported tells gdb.
const packet_size = rsp.dispatch.packet_size;

pub const Session = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// The ELF path as the discovery file and the client see it.
    elf: []const u8,
    port: u16,
    listener: std.Io.net.Server,
    /// The daemon's served session; null lists the port without
    /// serving it yet.
    live: ?*session_api.Session = null,
    /// The host clock the gdb target's transport wall reads, when a
    /// transport is attached to the live session.
    wall_clock: ?@import("ra8_session").run.pacer.HostClock = null,
    client: ?Client = null,

    /// One gdb connection, served a frame at a time. The buffers live in
    /// the struct so nothing moves while a poll or the packet reader holds
    /// an address into it.
    pub const Client = struct {
        stream: std.Io.net.Stream,
        wire: rsp.packet.Reader,
        incoming: [packet_size]u8,
        payload: [packet_size]u8,
        framed: [rsp.dispatch.server.limits.framed]u8,
        socket: rsp.poll.Socket,
        target: rsp.dispatch.zig_run.Target = undefined,
        stub: rsp.dispatch.Dispatch = undefined,
        last: []const u8 = &.{},
    };

    /// Accept a waiting gdb client, drain what it has sent, answer what is
    /// answerable, and keep a pumped continue going. Once per daemon turn.
    pub fn pump(self: *Session) void {
        if (self.client == null) self.accept();
        const c = &(self.client orelse return);
        self.drain(c);
        if (self.client != null) self.tick(c);
    }

    /// Close everything the session's gdb side holds.
    pub fn deinit(self: *Session) void {
        self.drop();
        self.listener.deinit(self.io);
    }

    fn accept(self: *Session) void {
        const fd = self.listener.socket.handle;
        const ready = sock_ready.wait(self.io, fd, 0) catch return;
        if (!ready.any()) return;
        const stream = self.listener.accept(self.io) catch return;
        const live = self.live orelse {
            stream.close(self.io);
            return;
        };
        live.setRunBudget(live.currentCore(), rsp.poll.chunk) catch {};
        self.client = .{
            .stream = stream,
            .wire = undefined,
            .incoming = undefined,
            .payload = undefined,
            .framed = undefined,
            .socket = .{ .handle = stream.socket.handle, .io = self.io },
        };
        const c = &(self.client.?);
        c.wire = rsp.packet.Reader.init(&c.incoming);
        if (self.wall_clock == null) self.wall_clock = @import("ra8_session").run.pacer.HostClock.init(self.io);
        c.target = .{ .session = live, .poll = c.socket.poll(), .pump = true, .wall = self.wall_clock.?.wall() };
        c.stub = .{ .zig = &c.target };
    }

    /// Read what the client has sent and answer each complete packet.
    fn drain(self: *Session, c: *Client) void {
        const fd = c.stream.socket.handle;
        var byte: [1]u8 = undefined;
        while (true) {
            const ready = sock_ready.wait(self.io, fd, 0) catch return;
            if (!ready.any()) return;
            const got = sock_ready.takeByte(self.io, fd, &byte, false) orelse {
                self.drop();
                return;
            };
            if (got == 0) {
                self.drop();
                return;
            }
            const event = c.wire.push(byte[0]) orelse continue;
            switch (event) {
                .ack, .interrupt => {},
                .resend => if (c.last.len > 0) {
                    const again = rsp.packet.frame(&c.framed, c.last) catch return;
                    if (!self.send(c, again)) return;
                },
                .corrupt, .overflow => if (!self.send(c, &[_]u8{rsp.packet.resend})) return,
                .packet => |request| if (!self.answer(c, request)) return,
            }
        }
    }

    /// Answer one packet; false when the connection has ended.
    fn answer(self: *Session, c: *Client, request: []const u8) bool {
        if (request.len == 1 and request[0] == 'k') {
            self.drop();
            return false;
        }
        if (request.len > 0 and request[0] == 'D') {
            _ = self.send(c, "$OK#8e");
            self.drop();
            return false;
        }
        if (std.mem.startsWith(u8, request, "qRcmd")) return monitor(self, c, request);
        const reply = c.stub.answer(request, &c.payload) catch return false;
        // A pumped resume that has not stopped yet sends nothing: gdb waits
        // for the stop reply, and the pump delivers it when the run ends.
        if (reply.len == 0 and resumes(request)) return true;
        if (resumes(request)) {
            // A resume that stopped inside this packet already printed.
            if (!self.consoleOut(c)) return false;
        }
        const framed = rsp.packet.frame(&c.framed, reply) catch return false;
        if (!self.send(c, framed)) return false;
        c.last = reply;
        return true;
    }

    /// Keep a pumped continue going, and deliver its stop reply.
    fn tick(self: *Session, c: *Client) void {
        if (!c.target.pending) return;
        const reply = rsp.dispatch.zig_run.pumpTick(&c.target, &c.payload) catch {
            _ = self.send(c, "$E00#a9");
            return;
        };
        if (reply.len == 0) return;
        if (!self.consoleOut(c)) return;
        const framed = rsp.packet.frame(&c.framed, reply) catch return;
        if (!self.send(c, framed)) return;
        c.last = framed;
    }

    /// Send the ITM port 0 text the run just produced as `O` packets
    /// (RA8EMU-1156): gdb takes them only while the target runs, so they
    /// go out between a resume and its stop reply, and the text is then
    /// forgotten. False when the connection has ended.
    fn consoleOut(self: *Session, c: *Client) bool {
        const live = self.live orelse return true;
        const port = live.itmPort(live.currentCore()) catch return true;
        var out = Sender{ .session = self, .client = c };
        rsp.console.send(&out, port, &c.framed) catch return false;
        return true;
    }

    fn send(self: *Session, c: *Client, bytes: []const u8) bool {
        sock_ready.sendAll(self.io, c.stream.socket.handle, bytes, 20) catch {
            self.drop();
            return false;
        };
        return true;
    }

    /// The writer console.send frames each `O` packet into and sends.
    const Sender = struct {
        session: *Session,
        client: *Client,

        pub const Error = error{Closed};

        pub fn writeAll(self: *Sender, bytes: []const u8) Error!void {
            if (!self.session.send(self.client, bytes)) return error.Closed;
        }
    };

    fn drop(self: *Session) void {
        const c = &(self.client orelse return);
        c.stream.close(self.io);
        self.client = null;
    }
};

/// The largest image a monitor reload reads, in bytes.
const max_image = 16 * 1024 * 1024;

/// A monitor command (RA8EMU-1155). `monitor reset halt`, `monitor reset`
/// and `monitor reload` all reboot the hosted session from the ELF it was
/// booted from, so a rebuild-and-relaunch from the IDE lands without
/// restarting the app. Anything else gets the empty reply, which gdb
/// reads as an unsupported monitor command. The replies carry no console
/// output, so gdb prints nothing.
fn monitor(self: *Session, c: *Session.Client, request: []const u8) bool {
    if (!std.mem.startsWith(u8, request, "qRcmd,")) return sendReply(self, c, "");
    const hex = request["qRcmd,".len..];
    var text: [64]u8 = undefined;
    if (hex.len == 0 or hex.len % 2 != 0 or hex.len / 2 > text.len) return sendReply(self, c, "");
    const len = hex.len / 2;
    for (0..len) |at| {
        text[at] = std.fmt.parseInt(u8, hex[at * 2 .. at * 2 + 2], 16) catch return sendReply(self, c, "");
    }
    const command = std.mem.trim(u8, text[0..len], " ");
    const known = std.mem.eql(u8, command, "reset halt") or
        std.mem.eql(u8, command, "reset") or std.mem.eql(u8, command, "reload");
    if (!known) return sendReply(self, c, "");
    const live = self.live orelse return sendReply(self, c, "");
    reboot(self, live) catch return sendReply(self, c, "");
    return sendReply(self, c, "OK");
}

/// Re-boot one live session from its ELF on disk (RA8EMU-1155). The load
/// resets the machine and leaves it paused, the same path ctl's `load`
/// takes against a served session.
fn reboot(self: *Session, live: *session_api.Session) !void {
    const image = try std.Io.Dir.cwd().readFileAlloc(self.io, self.elf, self.gpa, .limited(max_image));
    defer self.gpa.free(image);
    try live.load(live.currentCore(), image);
}

/// Frame and send one reply; false when the connection has ended.
fn sendReply(self: *Session, c: *Session.Client, body: []const u8) bool {
    const framed = rsp.packet.frame(&c.framed, body) catch return false;
    if (!self.send(c, framed)) return false;
    c.last = body;
    return true;
}

/// Whether a request is run control a pumped resume would answer with a
/// stop reply only later.
fn resumes(request: []const u8) bool {
    if (request.len == 0) return false;
    if (request[0] == 'c' or request[0] == 's') return true;
    if (std.mem.startsWith(u8, request, "vCont;")) {
        const first = request["vCont;".len..];
        return first.len > 0 and (first[0] == 'c' or first[0] == 'C' or first[0] == 's' or first[0] == 'S');
    }
    return false;
}
