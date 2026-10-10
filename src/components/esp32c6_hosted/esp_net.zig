//! Host TCP/UDP sockets behind the ESP32-C6 station interface.
const std = @import("std");
const dns = @import("esp_dns.zig");
const dns_host = @import("esp_dns_host.zig");
const worker = @import("esp_worker.zig");
const eth = @import("esp_eth.zig");
const frame = @import("esp_frame.zig");
const dhcp = @import("esp_dhcp.zig");
const Queue = @import("esp_queue.zig").Queue;
const udp_net = @import("esp_udp.zig");
const tape = @import("esp_tape.zig");
const Sock = @import("esp_sock.zig").Sock;
const host_net = @import("esp_host_net.zig");

pub const tcp_capacity: usize = 8;
const guest_window: u16 = eth.tcp_payload_max;
pub const network_queue_limit: usize = 2;

pub const Result = enum { unhandled, handled };

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

const TcpState = enum { empty, connecting, established, reset_pending };
const Control = enum { none, syn_ack, ack, window_update, fin, reset };

const TcpFlow = struct {
    state: TcpState = .empty,
    sock: Sock = .{},
    key: Key = undefined,
    route: eth.Route = undefined,
    opening_syn: u32 = 0,
    guest_next: u32 = 0,
    server_next: u32 = 0,
    guest_ack: u32 = 0,
    receive_window: u16 = 0,
    guest_fin: bool = false,
    host_fin_sent: bool = false,
    host_fin_acked: bool = false,
    shutdown_pending: bool = false,
    control: Control = .none,
    pending: [eth.tcp_payload_max]u8 = undefined,
    pending_len: usize = 0,
    pending_at: usize = 0,

    fn close(self: *TcpFlow) void {
        self.sock.close();
        self.* = .{};
    }
};

pub const Bridge = struct {
    tcp_flows: [tcp_capacity]TcpFlow = @splat(.{}),
    udp_bridge: udp_net.Bridge = .{},
    resolver: dns.Resolver = .{},
    tcp_cursor: usize = 0,
    dns_bridge: dns_host.Host = .{},
    tape: tape.Tape = .{},
    /// The host network the application handed over; none opens no socket.
    net: ?host_net.Net = null,
    /// The background worker DNS lookups run on; none resolves inline.
    worker: ?worker.Worker = null,

    pub fn deinit(self: *Bridge) void {
        for (&self.tcp_flows) |*flow| flow.close();
        self.udp_bridge.deinit();
        self.dns_bridge.deinit();
        self.tape.deinit();
        self.tcp_cursor = 0;
    }
    pub fn active(self: *const Bridge) bool {
        if (self.dns_bridge.job != null or self.udp_bridge.active()) return true;
        for (self.tcp_flows) |flow| if (flow.state != .empty) return true;
        return false;
    }

    /// Consumes supported station IPv4 traffic. Synthetic DHCP/ARP/ICMP run first.
    pub fn forward(self: *Bridge, queue: *Queue, ethernet: []const u8) Result {
        const ip = eth.ipv4(ethernet) orelse return .unhandled;
        if (ip.protocol == eth.proto_udp) {
            const datagram = eth.udp(ethernet) orelse return .handled;
            if (datagram.dst_port == dns.port and std.mem.eql(u8, &ip.dst_ip, &dhcp.server_ip)) {
                self.forwardDns(queue, ip, datagram);
            } else self.udp_bridge.forward(&self.tape, self.net, ip, datagram);
            return .handled;
        }
        if (ip.protocol == eth.proto_tcp) {
            const segment = eth.tcp(ip) orelse return .handled;
            self.forwardTcp(queue, ip, segment);
            return .handled;
        }
        return .unhandled;
    }

    /// Advances every live nonblocking socket without waiting.
    pub fn poll(self: *Bridge, queue: *Queue) void {
        self.dns_bridge.poll(&self.tape, queue, network_queue_limit);
        for (0..tcp_capacity) |step| {
            if (queue.len >= network_queue_limit) break;
            const index = (self.tcp_cursor + step) % tcp_capacity;
            self.pollTcp(queue, index);
        }
        self.tcp_cursor = (self.tcp_cursor + 1) % tcp_capacity;
        if (queue.len < network_queue_limit) self.udp_bridge.poll(&self.tape, queue);
    }

    fn forwardDns(self: *Bridge, queue: *Queue, ip: eth.Ipv4, datagram: eth.Udp) void {
        const route = replyRoute(ip, datagram.src_port, datagram.dst_port);
        if (self.tape.mode != .replay) return self.dns_bridge.start(datagram.data, route, self.resolver, self.worker);
        var answer: [eth.udp_payload_max]u8 = undefined;
        const recorded = self.tape.loadDns(datagram.data, &answer) orelse return;
        var ethernet: [frame.max_payload]u8 = undefined;
        const len = eth.udpFrame(&ethernet, route, recorded) orelse return;
        _ = queueEthernet(queue, ethernet[0..len]);
    }

    fn forwardTcp(self: *Bridge, queue: *Queue, ip: eth.Ipv4, segment: eth.Tcp) void {
        const key = makeKey(ip, segment.src_port, segment.dst_port);
        const found = self.findTcp(key);
        if (segment.flags & eth.TcpFlag.syn != 0) {
            if (found) |index| {
                const flow = &self.tcp_flows[index];
                if (flow.opening_syn == segment.seq) {
                    if (flow.state == .established) flow.control = .syn_ack;
                    self.queueControl(queue, index);
                    return;
                }
                flow.close();
                self.openTcp(queue, index, key, replyRoute(ip, segment.src_port, segment.dst_port), segment.seq, segment.window);
                return;
            }
            const index = self.freeTcp() orelse {
                self.queueStatelessReset(queue, replyRoute(ip, segment.src_port, segment.dst_port), segment.seq +% 1);
                return;
            };
            self.openTcp(queue, index, key, replyRoute(ip, segment.src_port, segment.dst_port), segment.seq, segment.window);
            return;
        }
        const index = found orelse return;
        const flow = &self.tcp_flows[index];
        if (segment.flags & eth.TcpFlag.rst != 0) {
            flow.close();
            return;
        }
        if (flow.state != .established) return;
        if (seqAfter(segment.ack, flow.server_next)) {
            flow.control = .reset;
            self.queueControl(queue, index);
            return;
        }
        if (!seqAfter(flow.guest_ack, segment.ack) and !seqAfter(segment.ack, flow.server_next)) {
            flow.guest_ack = segment.ack;
            flow.receive_window = segment.window;
        }
        if (flow.host_fin_sent and segment.ack == flow.server_next) flow.host_fin_acked = true;
        if (segment.seq != flow.guest_next) {
            flow.control = .ack;
            self.queueControl(queue, index);
            return;
        }
        if (segment.data.len != 0) {
            if (flow.pending_len != 0 or segment.data.len > flow.pending.len) {
                flow.control = .ack;
                self.queueControl(queue, index);
                return;
            }
            @memcpy(flow.pending[0..segment.data.len], segment.data);
            flow.pending_len = segment.data.len;
            flow.pending_at = 0;
            flow.guest_next +%= @intCast(segment.data.len);
        }
        if (segment.flags & eth.TcpFlag.fin != 0) {
            flow.guest_next +%= 1;
            flow.guest_fin = true;
            flow.shutdown_pending = true;
        }
        if (segment.data.len != 0 or segment.flags & eth.TcpFlag.fin != 0) {
            flow.control = .ack;
            self.queueControl(queue, index);
        }
        if (flow.control == .none) self.releaseClosed(index);
    }

    fn openTcp(self: *Bridge, queue: *Queue, index: usize, key: Key, route: eth.Route, syn: u32, window: u16) void {
        const flow = &self.tcp_flows[index];
        flow.* = .{
            .state = .connecting,
            .key = key,
            .route = route,
            .opening_syn = syn,
            .guest_next = syn +% 1,
            .server_next = 0xC6000000 +% @as(u32, @intCast(index)) +% 1,
            .guest_ack = 0xC6000000 +% @as(u32, @intCast(index)) +% 1,
            .receive_window = window,
        };
        const host = tape.Key{ .proto = .tcp, .ip = key.dst_ip, .port = key.dst_port };
        const opened = flow.sock.connect(&self.tape, self.net, host, hostAddress(key.dst_ip, key.dst_port)) catch {
            flow.state = .reset_pending;
            flow.control = .reset;
            self.queueControl(queue, index);
            return;
        };
        if (opened == .pending) return;
        flow.state = .established;
        flow.control = .syn_ack;
        self.queueControl(queue, index);
    }

    fn pollTcp(self: *Bridge, queue: *Queue, index: usize) void {
        const flow = &self.tcp_flows[index];
        if (flow.state == .empty) return;
        if (flow.control != .none) {
            self.queueControl(queue, index);
            return;
        }
        if (flow.state == .connecting) {
            const done = flow.sock.ready() catch {
                self.hardTcpError(index);
                return;
            };
            if (!done) return;
            flow.state = .established;
            flow.control = .syn_ack;
            self.queueControl(queue, index);
            return;
        }
        if (flow.pending_at < flow.pending_len) {
            const sent = flow.sock.send(flow.pending[flow.pending_at..flow.pending_len]) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {
                    if (err == error.ReplayDiverged) self.tape.miss("guest sent bytes the recording does not have", .{});
                    self.hardTcpError(index);
                    return;
                },
            };
            flow.pending_at += sent;
            if (flow.pending_at == flow.pending_len) {
                flow.pending_len = 0;
                flow.pending_at = 0;
                flow.control = .window_update;
            }
            return;
        }
        if (flow.shutdown_pending) {
            flow.sock.shutdownSend() catch {
                self.hardTcpError(index);
                return;
            };
            flow.shutdown_pending = false;
            return;
        }
        if (queue.len >= network_queue_limit or flow.host_fin_sent) {
            self.releaseClosed(index);
            return;
        }
        const in_flight = flow.server_next -% flow.guest_ack;
        if (in_flight >= flow.receive_window) return;
        const available: usize = @intCast(flow.receive_window - @as(u16, @intCast(in_flight)));
        var payload: [eth.tcp_payload_max]u8 = undefined;
        const got = flow.sock.recv(payload[0..@min(payload.len, available)], .copied) catch |err| switch (err) {
            error.WouldBlock => return,
            else => {
                self.hardTcpError(index);
                return;
            },
        };
        if (got == 0) {
            flow.control = .fin;
            self.queueControl(queue, index);
            return;
        }
        if (self.queueTcp(queue, flow.route, flow.server_next, flow.guest_next, eth.TcpFlag.psh | eth.TcpFlag.ack, guest_window, payload[0..got])) {
            flow.server_next +%= @intCast(got);
        }
    }

    fn queueControl(self: *Bridge, queue: *Queue, index: usize) void {
        const flow = &self.tcp_flows[index];
        if (flow.control == .none) return;
        var seq = flow.server_next;
        const acknowledgement = flow.guest_next;
        var flags: u8 = eth.TcpFlag.ack;
        var window: u16 = if (flow.pending_len == 0) guest_window else 0;
        switch (flow.control) {
            .none => unreachable,
            .syn_ack => {
                seq = flow.server_next -% 1;
                flags = eth.TcpFlag.syn | eth.TcpFlag.ack;
                window = guest_window;
            },
            .ack => {},
            .window_update => window = guest_window,
            .fin => flags = eth.TcpFlag.fin | eth.TcpFlag.ack,
            .reset => {
                flags = eth.TcpFlag.rst | eth.TcpFlag.ack;
                window = 0;
                if (flow.state == .reset_pending) seq = 0;
            },
        }
        if (!self.queueTcp(queue, flow.route, seq, acknowledgement, flags, window, &.{})) return;
        const sent = flow.control;
        flow.control = .none;
        switch (sent) {
            .fin => {
                flow.server_next +%= 1;
                flow.host_fin_sent = true;
            },
            .reset => flow.close(),
            else => {},
        }
    }

    fn hardTcpError(self: *Bridge, index: usize) void {
        const flow = &self.tcp_flows[index];
        flow.sock.close();
        flow.control = .reset;
        if (flow.state == .connecting) flow.state = .reset_pending;
    }

    fn releaseClosed(self: *Bridge, index: usize) void {
        const flow = &self.tcp_flows[index];
        if (flow.guest_fin and flow.host_fin_sent and flow.host_fin_acked and
            flow.pending_len == 0 and !flow.shutdown_pending and flow.control == .none) flow.close();
    }

    fn queueTcp(self: *Bridge, queue: *Queue, route: eth.Route, seq: u32, acknowledgement: u32, flags: u8, window: u16, payload: []const u8) bool {
        _ = self;
        if (queue.len >= network_queue_limit) return false;
        var ethernet: [frame.max_payload]u8 = undefined;
        const len = eth.tcpFrame(&ethernet, route, seq, acknowledgement, flags, window, payload) orelse return false;
        return queueEthernet(queue, ethernet[0..len]);
    }

    fn queueStatelessReset(self: *Bridge, queue: *Queue, route: eth.Route, acknowledgement: u32) void {
        _ = self.queueTcp(queue, route, 0, acknowledgement, eth.TcpFlag.rst | eth.TcpFlag.ack, 0, &.{});
    }

    fn findTcp(self: *Bridge, key: Key) ?usize {
        for (&self.tcp_flows, 0..) |*flow, index| if (flow.state != .empty and flow.key.eql(key)) return index;
        return null;
    }

    fn freeTcp(self: *Bridge) ?usize {
        for (&self.tcp_flows, 0..) |*flow, index| if (flow.state == .empty) return index;
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

fn seqAfter(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) > 0;
}
