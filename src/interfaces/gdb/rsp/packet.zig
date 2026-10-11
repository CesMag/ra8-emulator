//! The GDB remote serial protocol's framing: `$payload#cs`, where `cs` is
//! the payload's byte sum mod 256 in two lower-case hex digits, plus the
//! one-byte replies around it (`+` ack, `-` resend, 0x03 interrupt).
//!
//! Inside a payload `$`, `#`, `}` and `*` are escaped as `}` followed by the
//! byte xor 0x20. The stub never run-length encodes what it sends, and gdb
//! never run-length encodes what it sends to a stub, so `*` is only ever
//! seen escaped.
//!
//! Pure bytes in, bytes out: no socket, no engine. The server loop owns the
//! wire and the dispatcher owns what a payload means.
const std = @import("std");

pub const Error = error{NoSpace};

pub const ack: u8 = '+';
pub const resend: u8 = '-';
pub const interrupt: u8 = 0x03;

const start: u8 = '$';
const end: u8 = '#';
const escape: u8 = '}';
const flip: u8 = 0x20;

/// The payload's byte sum mod 256, the value the two hex digits carry.
pub fn checksum(payload: []const u8) u8 {
    var sum: u8 = 0;
    for (payload) |byte| sum +%= byte;
    return sum;
}

fn needsEscape(byte: u8) bool {
    return byte == start or byte == end or byte == escape or byte == '*';
}

/// Frames `payload` into `out` as `$escaped#cs` and returns the bytes
/// written. The checksum covers the escaped bytes, as sent.
pub fn frame(out: []u8, payload: []const u8) Error![]u8 {
    var at: usize = 0;
    try put(out, &at, start);
    var sum: u8 = 0;
    for (payload) |byte| {
        if (needsEscape(byte)) {
            try put(out, &at, escape);
            try put(out, &at, byte ^ flip);
            sum +%= escape +% (byte ^ flip);
        } else {
            try put(out, &at, byte);
            sum +%= byte;
        }
    }
    try put(out, &at, end);
    const digits = std.fmt.hex(sum);
    try put(out, &at, digits[0]);
    try put(out, &at, digits[1]);
    return out[0..at];
}

fn put(out: []u8, at: *usize, byte: u8) Error!void {
    if (at.* >= out.len) return error.NoSpace;
    out[at.*] = byte;
    at.* += 1;
}

/// What one byte off the wire completed, if anything.
pub const Event = union(enum) {
    ack,
    resend,
    interrupt,
    /// A whole packet whose checksum held. The slice is the unescaped
    /// payload and lives until the next `push`.
    packet: []const u8,
    /// A whole packet whose checksum did not hold: answer with `-`.
    corrupt,
    /// A packet longer than the reader's buffer: answer with `-`.
    overflow,
};

const State = enum { idle, body, escaped, high, low };

/// Turns the byte stream from gdb into events, one byte at a time, so the
/// server can feed it whatever a read returned without framing it first.
pub const Reader = struct {
    buffer: []u8,
    len: usize = 0,
    state: State = .idle,
    sum: u8 = 0,
    sent: u8 = 0,
    spilled: bool = false,

    pub fn init(buffer: []u8) Reader {
        return .{ .buffer = buffer };
    }

    pub fn push(self: *Reader, byte: u8) ?Event {
        switch (self.state) {
            .idle => return self.idle(byte),
            .body => self.body(byte),
            .escaped => {
                self.sum +%= byte;
                self.keep(byte ^ flip);
                self.state = .body;
            },
            .high => {
                self.sent = (hexValue(byte) orelse 0xff) << 4;
                self.state = .low;
            },
            .low => return self.finish(byte),
        }
        return null;
    }

    fn idle(self: *Reader, byte: u8) ?Event {
        switch (byte) {
            ack => return .ack,
            resend => return .resend,
            interrupt => return .interrupt,
            start => {
                self.len = 0;
                self.sum = 0;
                self.spilled = false;
                self.state = .body;
            },
            else => {},
        }
        return null;
    }

    fn body(self: *Reader, byte: u8) void {
        switch (byte) {
            end => self.state = .high,
            escape => {
                self.sum +%= byte;
                self.state = .escaped;
            },
            else => {
                self.sum +%= byte;
                self.keep(byte);
            },
        }
    }

    fn keep(self: *Reader, byte: u8) void {
        if (self.len >= self.buffer.len) {
            self.spilled = true;
            return;
        }
        self.buffer[self.len] = byte;
        self.len += 1;
    }

    fn finish(self: *Reader, byte: u8) Event {
        self.state = .idle;
        if (self.spilled) return .overflow;
        const low = hexValue(byte) orelse return .corrupt;
        if (self.sent | low != self.sum) return .corrupt;
        return .{ .packet = self.buffer[0..self.len] };
    }
};

fn hexValue(byte: u8) ?u8 {
    return std.fmt.charToDigit(byte, 16) catch null;
}
