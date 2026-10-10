//! tests/chip/periph/canfd_fifo_test.zig covers src/chip/periph/canfd_fifo.zig: the
//! receive queue behind a CAN-FD channel.
const std = @import("std");
const ra8 = @import("ra8");
const fifo = ra8.chip.periph.canfd_fifo;

fn framed(id: u32, dlc: u32, payload: u32) fifo.Frame {
    var frame = fifo.Frame{};
    frame.words[0] = id;
    frame.words[fifo.ptr.word] = dlc << fifo.ptr.dlc_shift;
    frame.words[3] = payload;
    return frame;
}

test "a fresh queue is empty and shows nothing" {
    const queue = fifo.Fifo{};
    try std.testing.expect(queue.empty());
    try std.testing.expectEqual(@as(usize, 0), queue.len());
    try std.testing.expectEqual(@as(u32, 0), queue.word(0));
    try std.testing.expect(queue.peek() == null);
}

test "a pushed frame is the one the window shows" {
    var queue = fifo.Fifo{};
    try std.testing.expect(queue.push(framed(0x123, 8, 0xDEAD_BEEF)));
    try std.testing.expect(!queue.empty());
    try std.testing.expectEqual(@as(u32, 0x123), queue.word(0));
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), queue.word(3));
    try std.testing.expectEqual(@as(u32, 8), queue.peek().?.dlc());
}

test "frames come back oldest first" {
    var queue = fifo.Fifo{};
    _ = queue.push(framed(0x111, 1, 0));
    _ = queue.push(framed(0x222, 2, 0));
    try std.testing.expectEqual(@as(usize, 2), queue.len());
    try std.testing.expectEqual(@as(u32, 0x111), queue.word(0));
    try std.testing.expect(queue.pop());
    try std.testing.expectEqual(@as(u32, 0x222), queue.word(0));
}

test "a full queue keeps what it has" {
    var queue = fifo.Fifo{};
    for (0..fifo.depth) |index| {
        try std.testing.expect(queue.push(framed(@intCast(index), 0, 0)));
    }
    try std.testing.expect(queue.full());
    try std.testing.expect(!queue.push(framed(0x7FF, 0, 0)));
    // The oldest is still the head: the stage that never opened is the one
    // that missed the frame.
    try std.testing.expectEqual(@as(u32, 0), queue.word(0));
    try std.testing.expectEqual(fifo.depth, queue.len());
}

test "a pop of an empty queue says so" {
    var queue = fifo.Fifo{};
    try std.testing.expect(!queue.pop());
    _ = queue.push(framed(0x0F0, 0, 0));
    try std.testing.expect(queue.pop());
    try std.testing.expect(!queue.pop());
}

test "the window reads zero once the last frame is taken" {
    var queue = fifo.Fifo{};
    _ = queue.push(framed(0x321, 4, 0xA5A5_A5A5));
    _ = queue.pop();
    try std.testing.expectEqual(@as(u32, 0), queue.word(0));
    try std.testing.expectEqual(@as(u32, 0), queue.word(3));
}

test "the ring wraps without losing order" {
    var queue = fifo.Fifo{};
    for (0..fifo.depth) |index| _ = queue.push(framed(@intCast(index + 1), 0, 0));
    _ = queue.pop();
    _ = queue.pop();
    _ = queue.push(framed(0x50, 0, 0));
    try std.testing.expectEqual(@as(u32, 3), queue.word(0));
    _ = queue.pop();
    try std.testing.expectEqual(@as(u32, 4), queue.word(0));
    _ = queue.pop();
    try std.testing.expectEqual(@as(u32, 0x50), queue.word(0));
}

test "an identifier is masked to 29 bits and the dlc read off PTR" {
    const frame = framed(0xFFFF_FFFF, 0xF, 0);
    try std.testing.expectEqual(fifo.id_mask.extended, frame.id());
    try std.testing.expectEqual(@as(u32, 0xF), frame.dlc());
}

test "a word past the frame reads zero" {
    var queue = fifo.Fifo{};
    _ = queue.push(framed(0x1, 0, 0));
    try std.testing.expectEqual(@as(u32, 0), queue.word(fifo.frame_words));
}
