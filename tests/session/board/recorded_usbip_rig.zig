//! Fixtures for the recorded USB/IP tests: a scripted bridge stand-in, the
//! device digest and a session with a history recorder.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("../fork_fixture.zig");

const usbfs = ra8.chip.periph.usbfs;
const pipe = usbfs.pipe;
const regs = ra8.chip.periph.usbhs.regs;
const usb = ra8.board.usb;
const traffic = usb.traffic;
const wire = ra8.usbip.wire;
const exp = ra8.usbip.exported;
const gpa = std.testing.allocator;

pub fn at(offset: u32) u32 {
    return usbfs.window.base + offset;
}

pub fn openOut(device: *usbfs.Device) void {
    device.write(at(regs.reg.pipesel), 2, 1);
    device.write(at(regs.reg.pipecfg), 2, (1 << pipe.cfg.kind_shift) | 2);
    device.write(at(regs.reg.pipemaxp), 2, 64);
    device.write(at(regs.reg.pipesel), 2, 0);
}

pub fn put(bytes: []u8, from: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[from..][0..4], value, .big);
}

/// A CMD_SUBMIT OUT on endpoint 2 with `data`, or a CMD_UNLINK of `victim`.
pub fn command(out: []u8, seqnum: u32, data: []const u8, victim: ?u32) []const u8 {
    @memset(out[0..wire.basic_len], 0);
    put(out, 0, if (victim == null) wire.cmd.submit else wire.cmd.unlink);
    put(out, 4, seqnum);
    if (victim) |v| {
        put(out, 20, v);
        return out[0..wire.basic_len];
    }
    put(out, 16, 2);
    put(out, 24, @intCast(data.len));
    @memcpy(out[wire.basic_len..][0..data.len], data);
    return out[0 .. wire.basic_len + data.len];
}

/// What the firmware sees of the device after the host's traffic.
pub fn digest(device: *usbfs.Device) u64 {
    var hash = std.hash.Wyhash.init(0);
    for ([_]u32{ regs.reg.intsts0, regs.reg.brdysts, regs.reg.bempsts }) |reg| {
        const value = device.read(at(reg), 2);
        hash.update(std.mem.asBytes(&value));
    }
    hash.update(std.mem.asBytes(&device.endpoints.overrun));
    hash.update(std.mem.asBytes(&device.endpoints.out[0].ready));
    var packet: [64]u8 = undefined;
    const got = device.endpoints.out[0].drain(&packet);
    hash.update(std.mem.asBytes(&got));
    hash.update(packet[0..got]);
    return hash.final();
}

/// The bridge's stand-in: scripted host commands taken through the same
/// session code a socket would feed, with the sink told as the bridge tells it.
pub const Host = struct {
    polls: u32 = 0,
    sink: ?traffic.Sink = null,
    urbs: exp.session.Session = .{},
    connected: bool = false,
    replayer: exp.replay.Replayer = .{},
    raw: [wire.basic_len + 64]u8 = undefined,

    pub fn say(self: *Host, event: traffic.Event) void {
        if (self.sink) |s| s.noteFn(s.context, event);
    }

    pub fn take(self: *Host, bytes: []const u8) void {
        var reader: std.Io.Reader = .fixed(bytes);
        var muted: std.Io.Writer.Discarding = .init(&.{});
        _ = self.urbs.receive(&reader, &muted.writer) catch unreachable;
    }

    pub fn poll(context: *anyopaque, device: *usbfs.Device, _: *const usbfs.host.Host) void {
        const self: *Host = @ptrCast(@alignCast(context));
        self.polls += 1;
        self.step(device);
    }

    /// What the host does at the `n`th poll.
    pub fn step(self: *Host, device: *usbfs.Device) void {
        const n = self.polls;
        if (n == 2) {
            self.say(.{ .kind = .import, .head = "1-1" });
            self.connected = true;
            self.urbs = .{ .sink = self.sink };
            return;
        }
        if (!self.connected) return;
        switch (n) {
            4 => self.take(command(&self.raw, 1, "hello", null)),
            6 => self.take(command(&self.raw, 2, "abcdefgh", null)),
            9 => self.take(command(&self.raw, 3, "", 2)),
            11 => {
                self.say(.{ .kind = .disconnect });
                self.connected = false;
                self.urbs = .{ .sink = self.sink };
                return;
            },
            else => {},
        }
        var muted: std.Io.Writer.Discarding = .init(&.{});
        const held = if (self.sink) |s| s.holdFn(s.context) else false;
        if (!held) _ = self.urbs.pump(device, &muted.writer) catch {};
    }

    pub fn tap(context: *anyopaque, sink: ?traffic.Sink) void {
        const self: *Host = @ptrCast(@alignCast(context));
        self.sink = sink;
        self.urbs.sink = sink;
    }

    pub fn feed(context: *anyopaque, device: *usbfs.Device, event: traffic.Event) anyerror!void {
        const self: *Host = @ptrCast(@alignCast(context));
        try self.replayer.feed(device, event);
    }

    pub fn restore(context: *anyopaque, event: traffic.Event) anyerror!void {
        const self: *Host = @ptrCast(@alignCast(context));
        try self.replayer.restore(event);
    }

    pub fn settle(context: *anyopaque, device: *usbfs.Device) void {
        const self: *Host = @ptrCast(@alignCast(context));
        self.replayer.settle(device);
    }

    pub fn drop(context: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(context));
        self.connected = false;
        self.urbs = .{ .sink = self.sink };
    }

    pub fn install(self: *Host, target: *usb.Usb) void {
        target.bridge = .{ .context = self, .pollFn = poll, .port = .{ .tapFn = tap, .feedFn = feed, .pumpFn = settle, .restoreFn = restore, .dropFn = drop } };
    }
};

pub const Run = struct {
    device: usbfs.Device = .{},
    target: usb.Usb = .{},
    script: usbfs.host.Host = .{},

    /// Polls the hook `count` times at rounds 1..count; the firmware takes
    /// the first packet after the 7th.
    pub fn go(self: *Run, h: *fixture.MockHarness, count: u32) u64 {
        openOut(&self.device);
        for (1..count + 1) |n| self.poll(h, @intCast(n));
        return digest(&self.device);
    }

    /// One poll at round `n`, and the firmware's take after the 7th.
    pub fn poll(self: *Run, h: *fixture.MockHarness, n: u32) void {
        h.grid_state.at.r = n;
        const hook = self.target.bridge.?;
        hook.pollFn(hook.context, &self.device, &self.script);
        if (n == 7) {
            var packet: [64]u8 = undefined;
            _ = self.device.endpoints.out[0].drain(&packet);
            self.device.endpoints.brdy = 0;
        }
    }
};

pub const Setup = struct {
    h: *fixture.MockHarness,
    history: ra8.session.history.History,

    pub fn open() !*Setup {
        const self = try gpa.create(Setup);
        self.h = try fixture.MockHarness.init(gpa);
        self.history = try ra8.session.history.History.init(gpa, undefined, 4);
        self.history.attachRecorder(&self.h.recorder);
        self.h.session.history = &self.history;
        self.h.recorder.observe(0);
        return self;
    }

    pub fn close(self: *Setup) void {
        self.history.deinit();
        if (self.h.session.async_traffic.queue) |*q| q.deinit();
        self.h.deinit();
        gpa.destroy(self);
    }
};
