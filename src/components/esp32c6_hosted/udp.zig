//! Bounded host UDP flows for the ESP32-C6 station bridge.
const std = @import("std");
const dhcp = @import("dhcp.zig");
const eth = @import("eth.zig");
const frame = @import("frame.zig");
const Queue = @import("queue.zig").Queue;
const tape = @import("tape/tape.zig");
const Sock = @import("sock.zig").Sock;
const host_net = @import("host_net.zig");

pub const capacity: usize = 8;

const Key = struct {
    src_ip: [4]u8,
    dst_ip: [4]u8,
    src_port: u16,
    dst_port: u16,

    fn eql(a: Key, b: Key) bool {
        return a.src_port == b.src_port and a.dst_port == b.dst_port and
            std.mem.eql(u8, &a.src_ip, &b.src_ip) and std.mem.eql(u8, &a.dst_ip, &b.dst_ip);
    }
};

const Flow = struct {
    used: bool = false,
    sock: Sock = .{},
    key: Key = undefined,
    route: eth.Route = undefined,
    generation: u64 = 0,
    pending: [eth.udp_payload_max]u8 = undefined,
    pending_len: usize = 0,

    fn close(self: *Flow) void {
        self.sock.close();
        self.* = .{};
    }
};

pub const Bridge = struct {
    flows: [capacity]Flow = @splat(.{}),
    generation: u64 = 0,
    cursor: usize = 0,

    pub fn deinit(self: *Bridge) void {
        for (&self.flows) |*flow| flow.close();
        self.generation = 0;
        self.cursor = 0;
    }
    pub fn active(self: *const Bridge) bool {
        for (self.flows) |flow| if (flow.used) return true;
        return false;
    }

    pub fn forward(self: *Bridge, run: *tape.Tape, net: ?host_net.Net, ip: eth.Ipv4, datagram: eth.Udp) void {
        const key = makeKey(ip, datagram.src_port, datagram.dst_port);
        const index = self.find(key) orelse self.allocate(run, net, key, replyRoute(ip, datagram.src_port, datagram.dst_port)) orelse return;
        const flow = &self.flows[index];
        if (flow.pending_len != 0 or datagram.data.len > flow.pending.len) return;
        const sent = flow.sock.send(datagram.data) catch |err| switch (err) {
            error.WouldBlock => {
                @memcpy(flow.pending[0..datagram.data.len], datagram.data);
                flow.pending_len = datagram.data.len;
                return;
            },
            else => {
                if (err == error.ReplayDiverged) run.miss("guest sent a datagram the recording does not have", .{});
                flow.close();
                return;
            },
        };
        if (sent == datagram.data.len) self.touch(flow) else flow.close();
    }

    pub fn poll(self: *Bridge, run: *tape.Tape, queue: *Queue) void {
        for (0..capacity) |step| self.pollOne(run, queue, (self.cursor + step) % capacity);
        self.cursor = (self.cursor + 1) % capacity;
    }

    fn pollOne(self: *Bridge, run: *tape.Tape, queue: *Queue, index: usize) void {
        const flow = &self.flows[index];
        if (!flow.used) return;
        if (flow.pending_len != 0) {
            const sent = flow.sock.send(flow.pending[0..flow.pending_len]) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {
                    if (err == error.ReplayDiverged) run.miss("guest sent a datagram the recording does not have", .{});
                    flow.close();
                    return;
                },
            };
            if (sent != flow.pending_len) {
                flow.close();
                return;
            }
            flow.pending_len = 0;
            self.touch(flow);
            return;
        }
        if (queue.len >= 2) return;
        var payload: [eth.udp_payload_max + 1]u8 = undefined;
        const got = flow.sock.recv(&payload, .whole_datagram) catch |err| switch (err) {
            error.WouldBlock => return,
            else => {
                flow.close();
                return;
            },
        };
        if (got > eth.udp_payload_max) return;
        var ethernet: [frame.max_payload]u8 = undefined;
        const len = eth.udpFrame(&ethernet, flow.route, payload[0..got]) orelse return;
        if (queueEthernet(queue, ethernet[0..len])) self.touch(flow);
    }

    fn allocate(self: *Bridge, run: *tape.Tape, net: ?host_net.Net, key: Key, route: eth.Route) ?usize {
        var index: usize = 0;
        var oldest: u64 = std.math.maxInt(u64);
        for (&self.flows, 0..) |*flow, i| {
            if (!flow.used) {
                index = i;
                break;
            }
            if (flow.generation < oldest) {
                oldest = flow.generation;
                index = i;
            }
        }
        const flow = &self.flows[index];
        if (flow.used) flow.close();
        var sock: Sock = .{};
        const host = tape.Key{ .proto = .udp, .ip = key.dst_ip, .port = key.dst_port };
        _ = sock.connect(run, net, host, hostAddress(key.dst_ip, key.dst_port)) catch return null;
        flow.* = .{ .used = true, .sock = sock, .key = key, .route = route };
        self.touch(flow);
        return index;
    }

    fn touch(self: *Bridge, flow: *Flow) void {
        self.generation +%= 1;
        flow.generation = self.generation;
    }

    fn find(self: *Bridge, key: Key) ?usize {
        for (&self.flows, 0..) |*flow, index| if (flow.used and flow.key.eql(key)) return index;
        return null;
    }
};

fn hostAddress(destination: [4]u8, port: u16) std.Io.net.Ip4Address {
    const host = if (std.mem.eql(u8, &destination, &dhcp.server_ip)) [4]u8{ 127, 0, 0, 1 } else destination;
    return .{ .bytes = host, .port = port };
}

fn makeKey(ip: eth.Ipv4, src_port: u16, dst_port: u16) Key {
    return .{ .src_ip = ip.src_ip, .dst_ip = ip.dst_ip, .src_port = src_port, .dst_port = dst_port };
}

fn replyRoute(ip: eth.Ipv4, src_port: u16, dst_port: u16) eth.Route {
    return .{
        .src_mac = ip.dst_mac,
        .dst_mac = ip.src_mac,
        .src_ip = ip.dst_ip,
        .dst_ip = ip.src_ip,
        .src_port = dst_port,
        .dst_port = src_port,
    };
}

fn queueEthernet(queue: *Queue, ethernet: []const u8) bool {
    var hosted: [frame.frame_size]u8 = undefined;
    frame.build(&hosted, .{ .interface = .sta, .if_num = 0 }, ethernet) catch return false;
    return queue.push(&hosted);
}
