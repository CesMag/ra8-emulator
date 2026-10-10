//! The watched place: what a store records, which stores both ends keep,
//! and the spellings that watch nothing at all.
const std = @import("std");
const ra8 = @import("ra8");
const watchpoint = ra8.session.watchpoint;

test "a store records its pc, its value and its width" {
    var watched = watchpoint.Watched{ .address = 0x2204_00A0 };
    watched.record(0x0200_FEDC, 0x0200_1235, 0x2204_00A0, 1, 5);
    try std.testing.expectEqual(@as(usize, 1), watched.seen);
    const store = watched.opening()[0];
    try std.testing.expectEqual(@as(u32, 0x0200_FEDC), store.pc);
    try std.testing.expectEqual(@as(u32, 5), store.value);
    try std.testing.expectEqual(@as(u8, 1), store.width);
    try std.testing.expectEqual(@as(u8, 0), store.offset);
    try std.testing.expectEqual(@as(u32, 0x0200_1235), store.lr);
}

test "a store inside the word records which byte it started at" {
    var watched = watchpoint.Watched{ .address = 0x2204_00A0 };
    watched.record(0x0200_FEDC, 0x0200_1235, 0x2204_00A2, 2, 0xBEEF);
    try std.testing.expectEqual(@as(u8, 2), watched.opening()[0].offset);
}

test "stores come back oldest first" {
    var watched = watchpoint.Watched{ .address = 0x2204_00A0 };
    watched.record(0x0200_1000, 0x0200_1235, 0x2204_00A0, 4, 1);
    watched.record(0x0200_2000, 0x0200_1235, 0x2204_00A0, 4, 2);
    const kept = watched.opening();
    try std.testing.expectEqual(@as(u32, 1), kept[0].value);
    try std.testing.expectEqual(@as(u32, 2), kept[1].value);
}

test "a value written in a loop keeps both ends and counts the middle" {
    var watched = watchpoint.Watched{ .address = 0x2204_00A0 };
    const written = watchpoint.limits.head + watchpoint.limits.tail + 5;
    for (0..written) |index| {
        watched.record(0x0200_1000, 0x0200_1235, 0x2204_00A0, 4, @intCast(index));
    }
    try std.testing.expectEqual(written, watched.seen);
    try std.testing.expectEqual(watchpoint.limits.head, watched.opening().len);
    // The opening says how the value got where it is.
    try std.testing.expectEqual(@as(u32, 0), watched.opening()[0].value);
    // The close is what a latch actually shows, so the last store written
    // has to survive however long the loop ran.
    var room: [watchpoint.limits.tail]watchpoint.Store = undefined;
    const last = watched.closing(&room);
    try std.testing.expectEqual(watchpoint.limits.tail, last.len);
    try std.testing.expectEqual(@as(u32, written - 1), last[last.len - 1].value);
    try std.testing.expectEqual(@as(usize, 5), watched.dropped());
}

test "the closing stores come back oldest first" {
    var watched = watchpoint.Watched{ .address = 0x2204_00A0 };
    for (0..40) |index| {
        watched.record(0x0200_1000, 0x0200_1235, 0x2204_00A0, 4, @intCast(index));
    }
    var room: [watchpoint.limits.tail]watchpoint.Store = undefined;
    const last = watched.closing(&room);
    for (last, 0..) |store, index| {
        try std.testing.expectEqual(@as(u32, @intCast(40 - last.len + index)), store.value);
    }
}

test "a short run drops nothing and repeats nothing" {
    var watched = watchpoint.Watched{ .address = 0x2204_00A0 };
    const written = watchpoint.limits.head + 2;
    for (0..written) |index| {
        watched.record(0x0200_1000, 0x0200_1235, 0x2204_00A0, 4, @intCast(index));
    }
    var room: [watchpoint.limits.tail]watchpoint.Store = undefined;
    const last = watched.closing(&room);
    try std.testing.expectEqual(@as(usize, 0), watched.dropped());
    try std.testing.expectEqual(@as(usize, 2), last.len);
    // The first store the close carries is the one straight after the
    // opening, so the two ends meet without overlapping.
    try std.testing.expectEqual(@as(u32, watchpoint.limits.head), last[0].value);
}

test "a run shorter than the opening closes on nothing" {
    var watched = watchpoint.Watched{ .address = 0x2204_00A0 };
    watched.record(0x0200_1000, 0x0200_1235, 0x2204_00A0, 4, 7);
    var room: [watchpoint.limits.tail]watchpoint.Store = undefined;
    try std.testing.expectEqual(@as(usize, 0), watched.closing(&room).len);
    try std.testing.expectEqual(@as(usize, 0), watched.dropped());
}

test "a place nothing wrote to keeps an empty list" {
    const watched = watchpoint.Watched{ .address = 0x2204_00A0 };
    try std.testing.expectEqual(@as(usize, 0), watched.seen);
    try std.testing.expectEqual(@as(usize, 0), watched.opening().len);
}

test "the window is a word wide" {
    const watched = watchpoint.Watched{ .address = 0x2204_00A0 };
    try std.testing.expectEqual(@as(u32, 0x2204_00A3), watched.end());
}

test "nothing named is nothing watched" {
    var buffer: [@sizeOf(ra8.board.image.elf.Header)]u8 = undefined;
    @memset(&buffer, 0);
    const head: *align(1) ra8.board.image.elf.Header =
        std.mem.bytesAsValue(ra8.board.image.elf.Header, &buffer);
    head.magic = .{ 0x7F, 'E', 'L', 'F' };
    head.class = 1;
    head.data = 1;
    head.e_machine = ra8.board.image.elf.em_arm;
    const image = try ra8.board.image.elf.Image.init(&buffer);
    try std.testing.expect(watchpoint.resolve(image, null) == null);
}

test "a literal place resolves without a symbol table" {
    var buffer: [@sizeOf(ra8.board.image.elf.Header)]u8 = undefined;
    @memset(&buffer, 0);
    const head: *align(1) ra8.board.image.elf.Header =
        std.mem.bytesAsValue(ra8.board.image.elf.Header, &buffer);
    head.magic = .{ 0x7F, 'E', 'L', 'F' };
    head.class = 1;
    head.data = 1;
    head.e_machine = ra8.board.image.elf.em_arm;
    const image = try ra8.board.image.elf.Image.init(&buffer);
    const watched = watchpoint.resolve(image, "0x220400A0") orelse return error.NotResolved;
    try std.testing.expectEqual(@as(u32, 0x2204_00A0), watched.address);
}

test "a name the image does not carry watches nothing" {
    var buffer: [@sizeOf(ra8.board.image.elf.Header)]u8 = undefined;
    @memset(&buffer, 0);
    const head: *align(1) ra8.board.image.elf.Header =
        std.mem.bytesAsValue(ra8.board.image.elf.Header, &buffer);
    head.magic = .{ 0x7F, 'E', 'L', 'F' };
    head.class = 1;
    head.data = 1;
    head.e_machine = ra8.board.image.elf.em_arm;
    const image = try ra8.board.image.elf.Image.init(&buffer);
    try std.testing.expect(watchpoint.resolve(image, "g_missing") == null);
}

test "a dereferencing place watches nothing" {
    var buffer: [@sizeOf(ra8.board.image.elf.Header)]u8 = undefined;
    @memset(&buffer, 0);
    const head: *align(1) ra8.board.image.elf.Header =
        std.mem.bytesAsValue(ra8.board.image.elf.Header, &buffer);
    head.magic = .{ 0x7F, 'E', 'L', 'F' };
    head.class = 1;
    head.data = 1;
    head.e_machine = ra8.board.image.elf.em_arm;
    const image = try ra8.board.image.elf.Image.init(&buffer);
    try std.testing.expect(watchpoint.resolve(image, "@0x220400A0+0x10") == null);
}

test "an offset is applied to a literal base" {
    var buffer: [@sizeOf(ra8.board.image.elf.Header)]u8 = undefined;
    @memset(&buffer, 0);
    const head: *align(1) ra8.board.image.elf.Header =
        std.mem.bytesAsValue(ra8.board.image.elf.Header, &buffer);
    head.magic = .{ 0x7F, 'E', 'L', 'F' };
    head.class = 1;
    head.data = 1;
    head.e_machine = ra8.board.image.elf.em_arm;
    const image = try ra8.board.image.elf.Image.init(&buffer);
    const watched = watchpoint.resolve(image, "0x22040000+0xA0") orelse return error.NotResolved;
    try std.testing.expectEqual(@as(u32, 0x2204_00A0), watched.address);
}

test "a watch nothing wrote to still prints its place" {
    var buffer: [@sizeOf(ra8.board.image.elf.Header)]u8 = undefined;
    @memset(&buffer, 0);
    const head: *align(1) ra8.board.image.elf.Header =
        std.mem.bytesAsValue(ra8.board.image.elf.Header, &buffer);
    head.magic = .{ 0x7F, 'E', 'L', 'F' };
    head.class = 1;
    head.data = 1;
    head.e_machine = ra8.board.image.elf.em_arm;
    const image = try ra8.board.image.elf.Image.init(&buffer);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const watched = watchpoint.Watched{ .address = 0x2204_00A0 };
    try watchpoint.print(&out.writer, image, "g_eoh_err", watched);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "0 store(s)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "g_eoh_err @0x220400A0") != null);
}

test "no watch prints nothing at all" {
    var buffer: [@sizeOf(ra8.board.image.elf.Header)]u8 = undefined;
    @memset(&buffer, 0);
    const head: *align(1) ra8.board.image.elf.Header =
        std.mem.bytesAsValue(ra8.board.image.elf.Header, &buffer);
    head.magic = .{ 0x7F, 'E', 'L', 'F' };
    head.class = 1;
    head.data = 1;
    head.e_machine = ra8.board.image.elf.em_arm;
    const image = try ra8.board.image.elf.Image.init(&buffer);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try watchpoint.print(&out.writer, image, null, null);
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}

test "a place written in a loop reports its last store, not just its first" {
    var buffer: [@sizeOf(ra8.board.image.elf.Header)]u8 = undefined;
    @memset(&buffer, 0);
    const head: *align(1) ra8.board.image.elf.Header =
        std.mem.bytesAsValue(ra8.board.image.elf.Header, &buffer);
    head.magic = .{ 0x7F, 'E', 'L', 'F' };
    head.class = 1;
    head.data = 1;
    head.e_machine = ra8.board.image.elf.em_arm;
    const image = try ra8.board.image.elf.Image.init(&buffer);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var watched = watchpoint.Watched{ .address = 0x2204_00A0 };
    for (0..900) |index| {
        watched.record(0x0200_1000, 0x0200_1235, 0x2204_00A0, 4, @intCast(index));
    }
    try watchpoint.print(&out.writer, image, "g_latched", watched);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "900 store(s)") != null);
    // The first store, the gap, and the last store all have to be there.
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "0x00000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "more, ending with") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "0x00000383") != null);
}

test "a store stamps the modelled period it landed in" {
    var clock: u64 = 417;
    var watched = watchpoint.Watched{ .address = 0x2200_09A8, .now = &clock };
    watched.record(0x0200_1234, 0x0200_1235, 0x2200_09A8, 4, 1);
    clock = 912;
    watched.record(0x0200_1234, 0x0200_1235, 0x2200_09A8, 4, 2);
    const opened = watched.opening();
    try std.testing.expectEqual(@as(u64, 417), opened[0].when);
    try std.testing.expectEqual(@as(u64, 912), opened[1].when);
}

test "without a timebase every stamp stays zero" {
    var watched = watchpoint.Watched{ .address = 0x2200_09A8 };
    watched.record(0x0200_1234, 0x0200_1235, 0x2200_09A8, 4, 1);
    try std.testing.expectEqual(@as(u64, 0), watched.opening()[0].when);
}

test "the stamp rides the ring, so the closing stores carry their own" {
    var clock: u64 = 0;
    var watched = watchpoint.Watched{ .address = 0x2200_09A8, .now = &clock };
    for (0..12) |step| {
        clock = @as(u64, step) * 100;
        watched.record(0x0200_1234, 0x0200_1235, 0x2200_09A8, 4, @intCast(step));
    }
    var room: [watchpoint.limits.tail]watchpoint.Store = undefined;
    const closing = watched.closing(&room);
    try std.testing.expectEqual(@as(u64, 800), closing[0].when);
    try std.testing.expectEqual(@as(u64, 1100), closing[closing.len - 1].when);
}
