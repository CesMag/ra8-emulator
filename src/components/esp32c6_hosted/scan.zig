//! The C6 model's Wi-Fi scan: one scripted access point, found every time.
//!
//! WifiScanStart is acknowledged and followed by Event_StaScanDone with
//! one result; WifiScanGetApNum answers 1 and WifiScanGetApRecords answers
//! the station's AP record ("benc", 02:03:04:05:06:07, channel 6, -55 dBm).
//! Field numbers follow esp-hosted-mcu v2.12.12 esp_hosted_rpc.proto.
//! The answers are modelled, not replayed from a bench capture yet.
const event = @import("event.zig");
const station = @import("station.zig");

pub const Error = event.Error;

pub const Id = struct {
    pub const req_start: u32 = 286;
    pub const req_ap_num: u32 = 288;
    pub const req_ap_records: u32 = 289;
    pub const event_done: u32 = 774;
};

/// Access points every scan finds.
pub const found: u32 = 1;

const wire_varint: u3 = 0;

fn unsigned(w: *event.Writer, number: u32, value: u32) Error!void {
    try w.key(number, wire_varint);
    try w.varint(value);
}

/// Writes the response body for scan request `id`; false when `id` is not
/// a scan request. ScanStart's body is empty (resp 0).
pub fn body(w: *event.Writer, id: u32) Error!bool {
    switch (id) {
        Id.req_start => {},
        Id.req_ap_num => try unsigned(w, 2, found),
        Id.req_ap_records => try records(w),
        else => return false,
    }
    return true;
}

fn records(w: *event.Writer) Error!void {
    try unsigned(w, 2, found);
    var buf: [48]u8 = undefined;
    var record: event.Writer = .{ .buf = &buf };
    try station.apRecord(&record);
    try w.field(3, record.written());
}

/// Writes Rpc_Event_StaScanDone: status 0 (success), `found` results.
pub fn eventBody(w: *event.Writer) Error!void {
    var buf: [8]u8 = undefined;
    var done: event.Writer = .{ .buf = &buf };
    try unsigned(&done, 2, found);
    try w.field(2, done.written());
}
