//! A save stream's memory section read as what the program did to it.
//!
//! The loader writes an image's segments into guest memory, so a rebuilt
//! image differs from the recorded one in the code bytes themselves before
//! a single instruction has run. Each byte is therefore read XOR the byte
//! its own image loaded at that address (zero where the image loaded
//! none): untouched code reads as zero in both runs, and anything the
//! program wrote reads as a real difference.
//!
//! Section layout (src/board/snapshot/memory.zig), little-endian: a region
//! count, then per region its base, length, page count and each page as an
//! offset and bytes (a page is 4 KiB, the last one of a region may be
//! short), then the external memory fabric's state to the end.
const std = @import("std");
const elf = @import("ra8_board").image.elf;

pub const page: u32 = 0x1000;
pub const max_regions: usize = 48;

pub const Error = error{ Truncated, BadValue };

/// One saved region: its pages are the `count` offset-and-bytes entries
/// that start at `pages`.
pub const Region = struct {
    base: u32,
    len: u32,
    count: u32,
    pages: []const u8,
};

/// The regions of a memory section and the bytes after them.
pub const Parsed = struct {
    regions: [max_regions]Region = undefined,
    len: usize = 0,
    tail: []const u8 = &.{},

    pub fn list(self: *const Parsed) []const Region {
        return self.regions[0..self.len];
    }
};

fn int(payload: []const u8, at: *usize) Error!u32 {
    if (payload.len - at.* < 4) return Error.Truncated;
    defer at.* += 4;
    return std.mem.readInt(u32, payload[at.*..][0..4], .little);
}

pub fn parse(payload: []const u8) Error!Parsed {
    var out: Parsed = .{};
    var at: usize = 0;
    const count = try int(payload, &at);
    if (count > max_regions) return Error.BadValue;
    for (0..count) |_| {
        const base = try int(payload, &at);
        const len = try int(payload, &at);
        const pages = try int(payload, &at);
        const start = at;
        for (0..pages) |_| {
            const offset = try int(payload, &at);
            if (offset >= len) return Error.BadValue;
            const size: usize = @min(page, len - offset);
            if (payload.len - at < size) return Error.Truncated;
            at += size;
        }
        out.regions[out.len] = .{ .base = base, .len = len, .count = pages, .pages = payload[start..at] };
        out.len += 1;
    }
    out.tail = payload[at..];
    return out;
}

/// The byte `image` loads at `address`, zero where it loads none.
pub fn loaded(image: elf.Image, address: u32) u8 {
    var index: u16 = 0;
    while (index < image.segmentCount()) : (index += 1) {
        const segment = image.loadSegment(index) orelse continue;
        if (address < segment.paddr) continue;
        const at = address - segment.paddr;
        if (at < segment.bytes.len) return segment.bytes[at];
    }
    return 0;
}

fn covered(image: elf.Image, from: u32, len: u32) bool {
    var index: u16 = 0;
    while (index < image.segmentCount()) : (index += 1) {
        const segment = image.loadSegment(index) orelse continue;
        const end = @as(u64, segment.paddr) + segment.bytes.len;
        if (segment.paddr < @as(u64, from) + len and end > from) return true;
    }
    return false;
}

/// Walks a region's saved pages in offset order.
pub const Pages = struct {
    rest: []const u8,
    len: u32,

    pub fn init(region: Region) Pages {
        return .{ .rest = region.pages, .len = region.len };
    }

    /// The next saved page's offset and bytes.
    pub fn next(self: *Pages) ?struct { offset: u32, bytes: []const u8 } {
        if (self.rest.len == 0) return null;
        const offset = std.mem.readInt(u32, self.rest[0..4], .little);
        const size: usize = @min(page, self.len - offset);
        const bytes = self.rest[4..][0..size];
        self.rest = self.rest[4 + size ..];
        return .{ .offset = offset, .bytes = bytes };
    }
};

/// The saved bytes of the page at `offset` in `region`, or null for a page
/// the section left out, which reads as zero.
pub fn saved(region: Region, offset: u32) ?[]const u8 {
    var pages = Pages.init(region);
    while (pages.next()) |entry| {
        if (entry.offset == offset) return entry.bytes;
        if (entry.offset > offset) return null;
    }
    return null;
}

/// One byte of a page as the program left it: the saved byte (zero when
/// the page was left out) XOR what the image loaded there.
pub fn effective(image: elf.Image, region: Region, offset: u32, in_page: ?[]const u8, i: usize) u8 {
    const byte: u8 = if (in_page) |bytes| bytes[i] else 0;
    return byte ^ loaded(image, region.base +% offset +% @as(u32, @intCast(i)));
}

/// Whether the page at `offset` can hold anything but zeros once the image
/// is taken out: it is saved, or the image loaded bytes into it.
pub fn live(image: elf.Image, region: Region, offset: u32, in_page: ?[]const u8) bool {
    return in_page != null or covered(image, region.base +% offset, @min(page, region.len - offset));
}

/// Where two memory sections first differ once each image is taken out,
/// with the raw bytes either run holds there.
pub const Spot = struct { address: u32, expected: u8, actual: u8 };

/// The lowest address at which the sections differ, or null when they
/// read the same. Regions are compared in section order; a region that
/// is not in both sections is reported at its base.
pub fn firstDifference(expected: Parsed, expected_image: elf.Image, actual: Parsed, actual_image: elf.Image) ?Spot {
    const regions = @min(expected.len, actual.len);
    for (expected.list()[0..regions], actual.list()[0..regions]) |a, b| {
        if (a.base != b.base or a.len != b.len) return .{ .address = a.base, .expected = 0, .actual = 0 };
        var offset: u32 = 0;
        while (offset < a.len) : (offset += page) {
            const in_a = saved(a, offset);
            const in_b = saved(b, offset);
            if (!live(expected_image, a, offset, in_a) and !live(actual_image, b, offset, in_b)) continue;
            const size: usize = @min(page, a.len - offset);
            for (0..size) |i| {
                if (effective(expected_image, a, offset, in_a, i) == effective(actual_image, b, offset, in_b, i)) continue;
                const raw_a: u8 = if (in_a) |bytes| bytes[i] else 0;
                const raw_b: u8 = if (in_b) |bytes| bytes[i] else 0;
                return .{ .address = a.base +% offset +% @as(u32, @intCast(i)), .expected = raw_a, .actual = raw_b };
            }
        }
    }
    if (expected.len != actual.len) return .{ .address = 0, .expected = 0, .actual = 0 };
    return null;
}

/// Feeds the section into `hasher` as what the program did to it: each
/// region's base and length, every page that can hold something, then the
/// bytes after the regions.
pub fn hash(hasher: *std.crypto.hash.Blake3, parsed: Parsed, image: elf.Image) void {
    var scratch: [page]u8 = undefined;
    for (parsed.list()) |region| {
        hasher.update(std.mem.asBytes(&std.mem.nativeToLittle(u32, region.base)));
        hasher.update(std.mem.asBytes(&std.mem.nativeToLittle(u32, region.len)));
        var offset: u32 = 0;
        while (offset < region.len) : (offset += page) {
            const in_page = saved(region, offset);
            if (!live(image, region, offset, in_page)) continue;
            const size: usize = @min(page, region.len - offset);
            var any = false;
            for (scratch[0..size], 0..) |*out, i| {
                out.* = effective(image, region, offset, in_page, i);
                any = any or out.* != 0;
            }
            if (!any) continue;
            hasher.update(std.mem.asBytes(&std.mem.nativeToLittle(u32, offset)));
            hasher.update(scratch[0..size]);
        }
    }
    hasher.update(parsed.tail);
}
