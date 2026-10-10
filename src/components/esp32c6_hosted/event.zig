//! Unsolicited RPC events from the ESP32-C6 model.
//!
//! esp-hosted-mcu 2.12 packs every RPC as protobuf `Rpc` (msg_type = 1,
//! msg_id = 2, uid = 3, the oneof payload numbered by its msg id), wraps it
//! in a TLV envelope (tag 0x01 endpoint name, tag 0x02 protobuf, 16-bit
//! little-endian lengths) and ships it on the serial interface, if_num 0.
//! Events use the `RPCEvt` endpoint. Proto3 drops zero scalars and empty
//! bytes, so an all-default body is a present, zero-length submessage.
const std = @import("std");
const frame = @import("frame.zig");

pub const Error = error{NoRoom} || frame.Error;

pub const endpoint_event: []const u8 = "RPCEvt";
pub const endpoint_response: []const u8 = "RPCRsp";
pub const tag_endpoint: u8 = 0x01;
pub const tag_data: u8 = 0x02;

/// `RpcType` values.
pub const Kind = enum(u32) { request = 1, response = 2, event = 3 };

/// `RpcId` values this model sends.
pub const Id = struct {
    pub const esp_init: u32 = 769;
};

const wire_varint: u3 = 0;
const wire_bytes: u3 = 2;

/// Appends protobuf and TLV octets into a fixed buffer.
pub const Writer = struct {
    buf: []u8,
    len: usize = 0,

    pub fn written(self: *const Writer) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn byte(self: *Writer, value: u8) Error!void {
        if (self.len >= self.buf.len) return Error.NoRoom;
        self.buf[self.len] = value;
        self.len += 1;
    }

    pub fn slice(self: *Writer, values: []const u8) Error!void {
        for (values) |value| try self.byte(value);
    }

    pub fn varint(self: *Writer, value: u64) Error!void {
        var rest = value;
        while (rest >= 0x80) : (rest >>= 7) try self.byte(@as(u8, @truncate(rest)) | 0x80);
        try self.byte(@truncate(rest));
    }

    pub fn key(self: *Writer, number: u32, wire: u3) Error!void {
        try self.varint(@as(u64, number) << 3 | wire);
    }

    /// A length-delimited field: key, length, then the octets.
    pub fn field(self: *Writer, number: u32, values: []const u8) Error!void {
        try self.key(number, wire_bytes);
        try self.varint(values.len);
        try self.slice(values);
    }

    /// A TLV record with a 16-bit little-endian length.
    pub fn tlv(self: *Writer, tag: u8, values: []const u8) Error!void {
        if (values.len > std.math.maxInt(u16)) return Error.NoRoom;
        try self.byte(tag);
        try self.byte(@truncate(values.len));
        try self.byte(@truncate(values.len >> 8));
        try self.slice(values);
    }
};

/// Packs `Rpc{msg_type, msg_id, payload[msg_id] = body}`; uid stays zero.
pub fn rpc(w: *Writer, kind: Kind, id: u32, body: []const u8) Error!void {
    try w.key(1, wire_varint);
    try w.varint(@backingInt(kind));
    try w.key(2, wire_varint);
    try w.varint(id);
    try w.field(id, body);
}

/// Packs `Rpc_Event_ESPInit{init_data = empty, cp_reset_reason}`.
pub fn espInit(w: *Writer, reset_reason: u32) Error!void {
    var body_buf: [8]u8 = undefined;
    var body: Writer = .{ .buf = &body_buf };
    if (reset_reason != 0) {
        try body.key(2, wire_varint);
        try body.varint(reset_reason);
    }
    try rpc(w, .event, Id.esp_init, body.written());
}

/// Wraps a packed protobuf in the endpoint and data TLVs.
pub fn envelope(w: *Writer, endpoint: []const u8, proto: []const u8) Error!void {
    try w.tlv(tag_endpoint, endpoint);
    try w.tlv(tag_data, proto);
}

/// Fills `out` with the frame announcing that the co-processor booted.
pub fn espInitFrame(out: *[frame.frame_size]u8, reset_reason: u32) Error!void {
    var proto_buf: [32]u8 = undefined;
    var proto: Writer = .{ .buf = &proto_buf };
    try espInit(&proto, reset_reason);
    var payload_buf: [64]u8 = undefined;
    var payload: Writer = .{ .buf = &payload_buf };
    try envelope(&payload, endpoint_event, proto.written());
    try frame.build(out, .{ .interface = .serial, .if_num = 0 }, payload.written());
}
