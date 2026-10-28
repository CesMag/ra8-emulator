//! One guest TCP connection the C6 bridge carries to a host socket: its
//! four-tuple key and the state the bridge keeps for it.
const std = @import("std");
const eth = @import("eth.zig");
const Sock = @import("sock.zig").Sock;

pub const Key = struct {
    src_ip: [4]u8,
    dst_ip: [4]u8,
    src_port: u16,
    dst_port: u16,

    pub fn eql(a: Key, b: Key) bool {
        return a.src_port == b.src_port and a.dst_port == b.dst_port and
            std.mem.eql(u8, &a.src_ip, &b.src_ip) and std.mem.eql(u8, &a.dst_ip, &b.dst_ip);
    }
};

pub const TcpState = enum { empty, connecting, established, reset_pending };
pub const Control = enum { none, syn_ack, ack, window_update, fin, reset };

pub const TcpFlow = struct {
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

    pub fn close(self: *TcpFlow) void {
        self.sock.close();
        self.* = .{};
    }
};
