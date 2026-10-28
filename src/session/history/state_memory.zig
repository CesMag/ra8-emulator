//! A save stream's memory section as the bytes the two runs hold.
//!
//! The loader writes an image's code and constants into guest memory, so a
//! rebuilt image differs from the recorded one in those bytes before a
//! single instruction has run. Those bytes, and only those, are left out:
//! the read-only segments of either image, and the load-time copies of
//! initialised data (a segment loaded at an address other than the one it
//! runs at). Everything else is compared as it is held, so a variable's
//! different initial value is a difference until the program writes it, and
//! a value both runs wrote is not one.
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

const pf_w: u32 = 2;

/// Whether `image` loads read-only bytes at `address`: code and constants,
/// or the flash copy a startup routine moves initialised data from.
fn ownBytes(image: elf.Image, address: u32) bool {
    var index: u16 = 0;
    while (index < image.segmentCount()) : (index += 1) {
        const segment = image.loadSegment(index) orelse continue;
        if (address < segment.paddr or address - segment.paddr >= segment.bytes.len) continue;
        if (segment.flags & pf_w == 0 or segment.paddr != segment.vaddr) return true;
    }
    return false;
}

/// The addresses two runs are not compared at: what either image loaded
/// as its own read-only bytes.
pub const Mask = struct {
    a: elf.Image,
    b: elf.Image,

    pub fn skips(self: Mask, address: u32) bool {
        return ownBytes(self.a, address) or ownBytes(self.b, address);
    }

    fn pageSkipped(self: Mask, from: u32, len: u32) bool {
        for (0..len) |i| if (!self.skips(from +% @as(u32, @intCast(i)))) return false;
        return true;
    }
};

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

/// One byte of a page as held: the saved byte (zero when the page was left
/// out), or zero where the mask skips the address.
pub fn held(mask: Mask, region: Region, offset: u32, in_page: ?[]const u8, i: usize) u8 {
    if (mask.skips(region.base +% offset +% @as(u32, @intCast(i)))) return 0;
    return if (in_page) |bytes| bytes[i] else 0;
}

/// Where two memory sections first differ, with the raw bytes either run
/// holds there.
pub const Spot = struct { address: u32, expected: u8, actual: u8 };

/// The lowest address at which the sections differ outside the mask, or
/// null when they read the same. Regions are compared in section order; a
/// region that is not in both sections is reported at its base.
pub fn firstDifference(expected: Parsed, actual: Parsed, mask: Mask) ?Spot {
    const regions = @min(expected.len, actual.len);
    for (expected.list()[0..regions], actual.list()[0..regions]) |a, b| {
        if (a.base != b.base or a.len != b.len) return .{ .address = a.base, .expected = 0, .actual = 0 };
        var offset: u32 = 0;
        while (offset < a.len) : (offset += page) {
            const in_a = saved(a, offset);
            const in_b = saved(b, offset);
            if (in_a == null and in_b == null) continue;
            const size: usize = @min(page, a.len - offset);
            for (0..size) |i| {
                const x = held(mask, a, offset, in_a, i);
                const y = held(mask, b, offset, in_b, i);
                if (x != y) return .{ .address = a.base +% offset +% @as(u32, @intCast(i)), .expected = x, .actual = y };
            }
        }
    }
    if (expected.len != actual.len) return .{ .address = 0, .expected = 0, .actual = 0 };
    return null;
}

/// Feeds the section into `hasher`: each region's base and length, every
/// page that holds anything outside the mask, then the bytes after the
/// regions. Two streams digest alike exactly when `firstDifference` finds
/// nothing between them under the same mask.
pub fn hash(hasher: *std.crypto.hash.Blake3, parsed: Parsed, mask: Mask) void {
    var scratch: [page]u8 = undefined;
    for (parsed.list()) |region| {
        hasher.update(std.mem.asBytes(&std.mem.nativeToLittle(u32, region.base)));
        hasher.update(std.mem.asBytes(&std.mem.nativeToLittle(u32, region.len)));
        var offset: u32 = 0;
        while (offset < region.len) : (offset += page) {
            const in_page = saved(region, offset) orelse continue;
            const size: usize = @min(page, region.len - offset);
            var any = false;
            for (scratch[0..size], 0..) |*out, i| {
                out.* = held(mask, region, offset, in_page, i);
                any = any or out.* != 0;
            }
            if (!any) continue;
            hasher.update(std.mem.asBytes(&std.mem.nativeToLittle(u32, offset)));
            hasher.update(scratch[0..size]);
        }
    }
    hasher.update(parsed.tail);
}
