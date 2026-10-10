//! The arrival counter behind --break-sym, and where a break resolves to.
const std = @import("std");
const ra8 = @import("ra8");
const breakpoint = ra8.session.breakpoint;
const elf = ra8.board.image.elf;

/// An ELF32 ARM header and nothing else: enough for `elf.Image.init` to
/// accept it, and carrying no symbol table, which is the shape that makes
/// a name unresolvable and leaves a literal address the only one that
/// works. The positive path here is deliberately the one that never
/// touches a symbol table.
fn headerOnly(buffer: []u8) elf.Image {
    @memset(buffer, 0);
    const head: *align(1) elf.Header = @ptrCast(buffer.ptr);
    head.magic = .{ 0x7f, 'E', 'L', 'F' };
    head.class = 1;
    head.data = 1;
    head.e_machine = elf.em_arm;
    return elf.Image.init(buffer) catch unreachable;
}

test "a break with no count stops on the first arrival" {
    var point = breakpoint.Break{ .address = 0x0200_1000 };
    try std.testing.expect(point.count());
    try std.testing.expect(point.reached);
    try std.testing.expectEqual(@as(u32, 1), point.seen);
}

test "a counted break does not stop before its arrival" {
    var point = breakpoint.Break{ .address = 0x0200_1000, .arrival = 3 };
    try std.testing.expect(!point.count());
    try std.testing.expect(!point.count());
    try std.testing.expect(!point.reached);
    try std.testing.expectEqual(@as(u32, 2), point.seen);
}

test "a counted break stops on the arrival it was given" {
    var point = breakpoint.Break{ .address = 0x0200_1000, .arrival = 3 };
    _ = point.count();
    _ = point.count();
    try std.testing.expect(point.count());
    try std.testing.expect(point.reached);
    try std.testing.expectEqual(@as(u32, 3), point.seen);
}

test "arrivals past the wanted one keep counting but stop nothing" {
    var point = breakpoint.Break{ .address = 0x0200_1000 };
    try std.testing.expect(point.count());
    try std.testing.expect(!point.count());
    try std.testing.expect(point.reached);
    try std.testing.expectEqual(@as(u32, 2), point.seen);
}

test "a run that falls short keeps the count it reached" {
    var point = breakpoint.Break{ .address = 0x0200_1000, .arrival = 10 };
    for (0..4) |_| _ = point.count();
    try std.testing.expect(!point.reached);
    try std.testing.expectEqual(@as(u32, 4), point.seen);
}

test "the watched address has the interworking bit cleared" {
    const odd = breakpoint.Break{ .address = 0x0200_1001 };
    const even = breakpoint.Break{ .address = 0x0200_1000 };
    try std.testing.expectEqual(@as(u64, 0x0200_1000), odd.watchedAddress());
    try std.testing.expectEqual(even.watchedAddress(), odd.watchedAddress());
}

test "a break starts unreached and uncounted" {
    const point = breakpoint.Break{ .address = 0x0200_1000 };
    try std.testing.expect(!point.reached);
    try std.testing.expectEqual(@as(u32, 0), point.seen);
    try std.testing.expectEqual(breakpoint.limits.first_arrival, point.arrival);
}

test "an unset break runs until an address no image reaches" {
    try std.testing.expectEqual(@as(u64, 0xFFFF_FFFF), breakpoint.limits.unreachable_address);
}

test "a literal address resolves without a symbol table" {
    var buffer: [@sizeOf(elf.Header)]u8 = undefined;
    const image = headerOnly(&buffer);
    const point = try breakpoint.resolve(image, "0x020074C1", 3);
    try std.testing.expectEqual(@as(u32, 0x0200_74C1), point.address);
    try std.testing.expectEqual(@as(u32, 3), point.arrival);
}

test "an offset applies to a literal address" {
    var buffer: [@sizeOf(elf.Header)]u8 = undefined;
    const image = headerOnly(&buffer);
    const point = try breakpoint.resolve(image, "0x020074AA+0x17", 1);
    try std.testing.expectEqual(@as(u32, 0x0200_74C1), point.address);
}

test "a name no symbol table carries is refused, not guessed at" {
    var buffer: [@sizeOf(elf.Header)]u8 = undefined;
    const image = headerOnly(&buffer);
    try std.testing.expectError(
        error.Unresolved,
        breakpoint.resolve(image, "priv_fat_get", 1),
    );
}

test "a break cannot dereference, having no memory to read yet" {
    var buffer: [@sizeOf(elf.Header)]u8 = undefined;
    const image = headerOnly(&buffer);
    try std.testing.expectError(
        error.NoDerefInBreak,
        breakpoint.resolve(image, "@s_mounts+0x40", 1),
    );
}

test "the thumb bit is off the watched address however the place carried it" {
    var buffer: [@sizeOf(elf.Header)]u8 = undefined;
    const image = headerOnly(&buffer);
    const point = try breakpoint.resolve(image, "0x020074C1", 1);
    try std.testing.expectEqual(@as(u64, 0x0200_74C0), point.watchedAddress());
}
