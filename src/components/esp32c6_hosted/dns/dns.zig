//! DNS replies backed by the host resolver for the C6 station gateway.
const std = @import("std");

pub const port: u16 = 53;
pub const max_answers: usize = 4;
pub const ttl_seconds: u32 = 60;

pub const LookupFn = *const fn (?*anyopaque, ?std.Io, []const u8, *[max_answers][4]u8) anyerror!u8;

pub const Resolver = struct {
    context: ?*anyopaque = null,
    /// The host Io; without one, host lookups fail and the guest gets SERVFAIL.
    io: ?std.Io = null,
    lookupFn: LookupFn = hostLookup,

    pub fn lookup4(self: Resolver, name: []const u8, out: *[max_answers][4]u8) !u8 {
        return self.lookupFn(self.context, self.io, name, out);
    }
};

/// Writes a DNS response. Null means the request is malformed and should be ignored.
pub fn answer(out: []u8, request: []const u8, resolver: Resolver) ?usize {
    if (request.len < 12 or out.len < 12) return null;
    const request_flags = be16(request[2..4]);
    if (be16(request[4..6]) != 1) return null;
    const question_end = questionEnd(request) orelse return null;
    const question = request[12..question_end];
    const qtype = be16(request[question_end - 4 .. question_end - 2]);
    const qclass = be16(request[question_end - 2 .. question_end]);
    if (qclass != 1) return null;

    var flags: u16 = 0x8000 | 0x0080 | (request_flags & 0x0100);
    var addresses: [max_answers][4]u8 = undefined;
    var count: u8 = 0;
    const opcode = (request_flags >> 11) & 0xF;
    if (opcode != 0) {
        flags |= 4;
    } else if (qtype == 1) {
        var name: [253]u8 = undefined;
        const name_len = decodeName(request[12 .. question_end - 4], &name) orelse return null;
        count = resolver.lookup4(name[0..name_len], &addresses) catch blk: {
            flags |= 2;
            break :blk 0;
        };
        if (count > max_answers) count = max_answers;
    }

    const answer_bytes = @as(usize, count) * 16;
    const needed = 12 + question.len + answer_bytes;
    if (needed > out.len) {
        flags |= 0x0200;
        count = 0;
    }
    const final_len = 12 + question.len + @as(usize, count) * 16;
    @memset(out[0..final_len], 0);
    @memcpy(out[0..2], request[0..2]);
    std.mem.writeInt(u16, out[2..4], flags, .big);
    std.mem.writeInt(u16, out[4..6], 1, .big);
    std.mem.writeInt(u16, out[6..8], count, .big);
    @memcpy(out[12 .. 12 + question.len], question);
    var at = 12 + question.len;
    for (addresses[0..count]) |address| {
        out[at] = 0xC0;
        out[at + 1] = 0x0C;
        std.mem.writeInt(u16, out[at + 2 ..][0..2], 1, .big);
        std.mem.writeInt(u16, out[at + 4 ..][0..2], 1, .big);
        std.mem.writeInt(u32, out[at + 6 ..][0..4], ttl_seconds, .big);
        std.mem.writeInt(u16, out[at + 10 ..][0..2], 4, .big);
        @memcpy(out[at + 12 .. at + 16], &address);
        at += 16;
    }
    return final_len;
}

fn questionEnd(request: []const u8) ?usize {
    var at: usize = 12;
    var encoded: usize = 1;
    while (at < request.len) {
        const len = request[at];
        if (len & 0xC0 != 0 or len > 63) return null;
        at += 1;
        if (len == 0) break;
        if (at + len > request.len) return null;
        encoded += len + 1;
        if (encoded > 254) return null;
        at += len;
    }
    if (at + 4 > request.len) return null;
    return at + 4;
}

fn decodeName(encoded: []const u8, out: *[253]u8) ?usize {
    var source: usize = 0;
    var target: usize = 0;
    while (source < encoded.len) {
        const len: usize = encoded[source];
        source += 1;
        if (len == 0) return target;
        if (source + len > encoded.len or target + len + @intFromBool(target != 0) > out.len) return null;
        if (target != 0) {
            out[target] = '.';
            target += 1;
        }
        @memcpy(out[target .. target + len], encoded[source .. source + len]);
        source += len;
        target += len;
    }
    return null;
}

fn hostLookup(_: ?*anyopaque, maybe_io: ?std.Io, name: []const u8, out: *[max_answers][4]u8) !u8 {
    const io = maybe_io orelse return error.NoHostIo;
    const Result = std.Io.net.HostName.LookupResult;
    var buffer: [16]Result = undefined;
    var results: std.Io.Queue(Result) = .init(&buffer);
    const host: std.Io.net.HostName = try .init(name);
    try host.lookup(io, &results, .{ .port = 0, .family = .ip4 });
    var count: u8 = 0;
    while (results.getOne(io)) |result| {
        const octets = switch (result) {
            .address => |address| switch (address) {
                .ip4 => |ip4| ip4.bytes,
                .ip6 => continue,
            },
            .canonical_name => continue,
        };
        if (count == max_answers) continue;
        var duplicate = false;
        for (out[0..count]) |seen| duplicate = duplicate or std.mem.eql(u8, &seen, &octets);
        if (duplicate) continue;
        out[count] = octets;
        count += 1;
    } else |err| switch (err) {
        error.Closed => {},
        else => |other| return other,
    }
    return count;
}

fn be16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, @ptrCast(bytes.ptr), .big);
}
