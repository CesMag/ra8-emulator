//! Tests for src/board/run/soak_watch.zig.
const std = @import("std");
const ra8 = @import("ra8");
const soak = ra8.board.run.soak;
const soak_watch = soak.soak_watch;

/// Four words of memory at 0x2000_0000; anything else is unreadable.
const Fake = struct {
    words: [4]u32 = .{ 0xEFEF_EFEF, 0xEFEF_EFEF, 0xFEED_FACE, 0 },

    pub fn readWord(self: *const Fake, address: u32) !u32 {
        if (address < 0x2000_0000 or address >= 0x2000_0010) return error.Unmapped;
        return self.words[(address - 0x2000_0000) / 4];
    }
};

fn watchTwo() !soak_watch.Watch {
    var watch: soak_watch.Watch = .{};
    try watch.add(.{ .address = 0x2000_0004, .expected = 0xEFEF_EFEF, .kind = .stack_canary });
    try watch.add(.{ .address = 0x2000_0008, .expected = 0xFEED_FACE, .kind = .heap_guard });
    return watch;
}

test "an empty watch never finds a change" {
    const watch: soak_watch.Watch = .{};
    try std.testing.expect(watch.changed(&Fake{}) == null);
}

test "words that hold their values are not a change" {
    const watch = try watchTwo();
    try std.testing.expect(watch.changed(&Fake{}) == null);
}

test "the first changed word names its kind and address" {
    const watch = try watchTwo();
    var memory = Fake{};
    memory.words[2] = 0;
    const found = watch.changed(&memory) orelse return error.NoChange;
    try std.testing.expectEqual(soak.Kind.heap_guard, found.kind);
    try std.testing.expectEqual(@as(u32, 0x2000_0008), found.address);
    memory.words[1] = 0x1234;
    try std.testing.expectEqual(soak.Kind.stack_canary, watch.changed(&memory).?.kind);
}

test "an unreadable word is skipped, not a change" {
    var watch: soak_watch.Watch = .{};
    try watch.add(.{ .address = 0x1000_0000, .expected = 1, .kind = .stack_canary });
    try std.testing.expect(watch.changed(&Fake{}) == null);
}

test "a full watch refuses another word" {
    var watch: soak_watch.Watch = .{};
    for (0..soak_watch.max_words) |_| try watch.add(.{ .address = 0, .expected = 0, .kind = .heap_guard });
    try std.testing.expectError(error.Full, watch.add(.{ .address = 0, .expected = 0, .kind = .heap_guard }));
}

test "an armed soak ends on a changed word and names it" {
    var state = soak.Soak{ .armed = true, .watch = try watchTwo() };
    var memory = Fake{};
    state.check(&memory, 5);
    try std.testing.expect(!state.ended());
    memory.words[1] = 0;
    state.check(&memory, 120_000_000_000);
    const event = state.event orelse return error.NoEvent;
    try std.testing.expectEqual(soak.Kind.stack_canary, event.kind);
    var buffer: [128]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buffer);
    try state.line(&stream);
    try std.testing.expectEqualStrings("soak: stopped on stack canary overwritten at 120.000000000 s virtual, core 0, word 0x20000004\n", stream.buffered());
}

test "an unarmed soak reads nothing" {
    var state = soak.Soak{ .watch = try watchTwo() };
    var memory = Fake{};
    memory.words[1] = 0;
    state.check(&memory, 1);
    try std.testing.expect(!state.ended());
}

test "drop forgets one kind and keeps the rest in order" {
    var watch = try watchTwo();
    try watch.add(.{ .address = 0x2000_0000, .expected = 0xEFEF_EFEF, .kind = .stack_canary });
    watch.drop(.stack_canary);
    try std.testing.expectEqual(@as(usize, 1), watch.list().len);
    try std.testing.expectEqual(soak.Kind.heap_guard, watch.list()[0].kind);
}
