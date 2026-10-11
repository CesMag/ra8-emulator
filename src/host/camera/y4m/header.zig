//! The YUV4MPEG2 stream header and the size of one frame (RA8EMU-499).
//!
//! A Y4M file is one text header line, then every frame as a "FRAME" line
//! followed by its planes: Y at full size, then U and V at the chroma size
//! the C tag names. Only 8-bit progressive streams are read; an interlaced
//! or deeper stream is refused, not guessed at. With no F tag the rate is
//! taken as 25:1 and with no C tag the chroma as 4:2:0, the Y4M defaults.
const std = @import("std");

pub const magic = "YUV4MPEG2";

pub const Error = error{ BadHeader, Unsupported };

pub const Chroma = enum { c420, c422, c444, mono };

pub const Header = struct {
    width: u32 = 0,
    height: u32 = 0,
    fps_num: u32 = 25,
    fps_den: u32 = 1,
    chroma: Chroma = .c420,

    /// Width and height of each chroma plane; zero for a mono stream.
    pub fn chromaSize(self: Header) struct { width: u32, height: u32 } {
        return switch (self.chroma) {
            .c420 => .{ .width = (self.width + 1) / 2, .height = (self.height + 1) / 2 },
            .c422 => .{ .width = (self.width + 1) / 2, .height = self.height },
            .c444 => .{ .width = self.width, .height = self.height },
            .mono => .{ .width = 0, .height = 0 },
        };
    }

    /// Bytes of plane data after each FRAME line.
    pub fn frameBytes(self: Header) u64 {
        const plane = self.chromaSize();
        return @as(u64, self.width) * self.height + 2 * @as(u64, plane.width) * plane.height;
    }
};

/// Read the header line, without its newline.
pub fn parse(line: []const u8) Error!Header {
    var tokens = std.mem.tokenizeScalar(u8, line, ' ');
    const first = tokens.next() orelse return error.BadHeader;
    if (!std.mem.eql(u8, first, magic)) return error.BadHeader;
    var header = Header{};
    while (tokens.next()) |token| try take(&header, token[0], token[1..]);
    if (header.width == 0 or header.height == 0) return error.BadHeader;
    if (header.fps_num == 0 or header.fps_den == 0) return error.BadHeader;
    return header;
}

fn take(header: *Header, tag: u8, value: []const u8) Error!void {
    switch (tag) {
        'W' => header.width = number(value) catch return error.BadHeader,
        'H' => header.height = number(value) catch return error.BadHeader,
        'F' => {
            const colon = std.mem.indexOfScalar(u8, value, ':') orelse return error.BadHeader;
            header.fps_num = number(value[0..colon]) catch return error.BadHeader;
            header.fps_den = number(value[colon + 1 ..]) catch return error.BadHeader;
        },
        'C' => header.chroma = try chroma(value),
        'I' => if (!std.mem.eql(u8, value, "p") and !std.mem.eql(u8, value, "?")) return error.Unsupported,
        else => {},
    }
}

fn number(text: []const u8) !u32 {
    return std.fmt.parseInt(u32, text, 10);
}

fn chroma(value: []const u8) Error!Chroma {
    const names = [_]struct { []const u8, Chroma }{
        .{ "420jpeg", .c420 }, .{ "420paldv", .c420 }, .{ "420mpeg2", .c420 },
        .{ "420", .c420 },     .{ "422", .c422 },      .{ "444", .c444 },
        .{ "mono", .mono },
    };
    for (names) |entry| if (std.mem.eql(u8, value, entry[0])) return entry[1];
    return error.Unsupported;
}
