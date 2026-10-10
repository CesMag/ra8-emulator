//! The scripted station side of the C6 model: the one access point the
//! station joins, the addresses it reports and the events it raises.
//!
//! Values follow ra8-firmware's host-test model
//! (tests/mocks/inc/ra8_c6_model.h): station MAC 09:08:07:06:05:04, AP
//! "benc" at 02:03:04:05:06:07 on channel 6 with RSSI -55 dBm, and
//! WIFI_EVENT_STA_START (2) after the station starts. Field numbers follow
//! esp-hosted-mcu v2.12.12 common/proto/esp_hosted_rpc.proto.
const frame = @import("frame.zig");
const event = @import("event.zig");
const scan = @import("scan.zig");

pub const Error = event.Error;

pub const Id = struct {
    pub const req_mac: u32 = 257;
    pub const req_start: u32 = 280;
    pub const req_connect: u32 = 282;
    pub const req_ap_info: u32 = 294;
    pub const event_no_args: u32 = 773;
    pub const event_connected: u32 = 775;
};

pub const mac = [6]u8{ 9, 8, 7, 6, 5, 4 };
pub const bssid = [6]u8{ 2, 3, 4, 5, 6, 7 };
pub const ssid: []const u8 = "benc";
pub const channel: u32 = 6;
pub const rssi: i32 = -55;
/// WIFI_EVENT_STA_START.
pub const sta_start: u32 = 2;

const wire_varint: u3 = 0;

fn unsigned(w: *event.Writer, number: u32, value: u32) Error!void {
    try w.key(number, wire_varint);
    try w.varint(value);
}

/// int32 fields go on the wire sign-extended to 64 bits.
fn signed(w: *event.Writer, number: u32, value: i32) Error!void {
    try w.key(number, wire_varint);
    try w.varint(@bitCast(@as(i64, value)));
}

/// Writes the response body for request `id`; false when it isn't one of
/// the station requests with a body.
pub fn body(w: *event.Writer, id: u32) Error!bool {
    switch (id) {
        Id.req_mac => try w.field(1, &mac),
        Id.req_ap_info => try apInfo(w),
        else => return scan.body(w, id),
    }
    return true;
}

/// Writes a `wifi_ap_record` for the scripted access point.
pub fn apRecord(w: *event.Writer) Error!void {
    try w.field(1, &bssid);
    try w.field(2, ssid);
    try unsigned(w, 3, channel);
    try signed(w, 5, rssi);
}

fn apInfo(w: *event.Writer) Error!void {
    var buf: [48]u8 = undefined;
    var record: event.Writer = .{ .buf = &buf };
    try apRecord(&record);
    try w.field(2, record.written());
}

/// The event that follows the answer to request `id`, if any.
pub fn followUp(id: u32) ?u32 {
    return switch (id) {
        Id.req_start => Id.event_no_args,
        Id.req_connect => Id.event_connected,
        scan.Id.req_start => scan.Id.event_done,
        else => null,
    };
}

/// Writes the body of event `id` (WifiEventNoArgs, StaConnected or
/// StaScanDone).
pub fn eventBody(w: *event.Writer, id: u32) Error!void {
    if (id == scan.Id.event_done) return scan.eventBody(w);
    if (id == Id.event_no_args) return unsigned(w, 2, sta_start);
    var buf: [48]u8 = undefined;
    var inner: event.Writer = .{ .buf = &buf };
    try inner.field(1, ssid);
    try unsigned(&inner, 2, @intCast(ssid.len));
    try inner.field(3, &bssid);
    try unsigned(&inner, 4, channel);
    try w.field(2, inner.written());
}

/// Builds the serial frame carrying event `id` on endpoint RPCEvt.
pub fn eventFrame(out: *[frame.frame_size]u8, id: u32) Error!void {
    var body_buf: [64]u8 = undefined;
    var b: event.Writer = .{ .buf = &body_buf };
    try eventBody(&b, id);
    var proto_buf: [96]u8 = undefined;
    var proto: event.Writer = .{ .buf = &proto_buf };
    try event.rpc(&proto, .event, id, b.written());
    var payload_buf: [128]u8 = undefined;
    var payload: event.Writer = .{ .buf = &payload_buf };
    try event.envelope(&payload, event.endpoint_event, proto.written());
    try frame.build(out, .{ .interface = .serial, .if_num = 0 }, payload.written());
}
