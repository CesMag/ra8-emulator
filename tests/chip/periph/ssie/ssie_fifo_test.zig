const std = @import("std");
const testing = std.testing;
const ra8 = @import("ra8");
const fifo = ra8.chip.periph.ssie_fifo;

test "a fresh stage is quiet and empty" {
    const stage = fifo.Stage{};
    try testing.expect(stage.quiet());
    try testing.expect(stage.empty());
    try testing.expect(!stage.full());
}

test "the depth is the part's thirty-two stages" {
    try testing.expectEqual(@as(usize, 32), fifo.depth.stages);
}

test "a push holds the sample" {
    var stage = fifo.Stage{};
    try testing.expect(stage.push(0xABCD));
    try testing.expectEqual(@as(usize, 1), stage.held);
    try testing.expect(!stage.empty());
    try testing.expectEqual(@as(u32, 0xABCD), stage.pending()[0]);
}

test "pushes stay in order, oldest first" {
    var stage = fifo.Stage{};
    for (0..4) |i| _ = stage.push(@intCast(i + 1));
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, stage.pending());
}

test "the stage fills to the depth and no further" {
    var stage = fifo.Stage{};
    for (0..fifo.depth.stages) |i| try testing.expect(stage.push(@intCast(i)));
    try testing.expect(stage.full());
    try testing.expect(!stage.push(0xDEAD));
    try testing.expectEqual(@as(usize, fifo.depth.stages), stage.held);
}

test "a store past the last stage is counted as an overrun" {
    var stage = fifo.Stage{};
    for (0..fifo.depth.stages + 3) |i| _ = stage.push(@intCast(i));
    try testing.expectEqual(@as(u32, 3), stage.overruns);
    try testing.expect(!stage.quiet());
}

test "a drain empties without counting a loss" {
    var stage = fifo.Stage{};
    _ = stage.push(1);
    _ = stage.push(2);
    stage.clear();
    try testing.expect(stage.empty());
    try testing.expectEqual(@as(u32, 0), stage.discarded);
}

test "a flush counts what it threw away" {
    var stage = fifo.Stage{};
    for (0..5) |i| _ = stage.push(@intCast(i));
    stage.flush();
    try testing.expect(stage.empty());
    try testing.expectEqual(@as(u32, 5), stage.discarded);
}

test "a flush of an empty stage discards nothing" {
    var stage = fifo.Stage{};
    stage.flush();
    try testing.expectEqual(@as(u32, 0), stage.discarded);
    try testing.expect(stage.quiet());
}

test "an empty FIFO reports a zero transmit count" {
    try testing.expectEqual(@as(u32, 0), fifo.transmitCount(0));
}

test "the transmit count lands in TDC" {
    try testing.expectEqual(@as(u32, 0x0100_0000), fifo.transmitCount(1));
    try testing.expectEqual(@as(u32, 0x0500_0000), fifo.transmitCount(5));
}

test "a full FIFO reads the depth in TDC and stays inside the field" {
    const packed_count = fifo.transmitCount(fifo.depth.stages);
    try testing.expectEqual(@as(u32, 0x2000_0000), packed_count);
    try testing.expectEqual(packed_count, packed_count & fifo.status.tdc_mask);
}

test "a count past the depth saturates rather than wrapping the field" {
    const packed_count = fifo.transmitCount(99);
    try testing.expectEqual(fifo.transmitCount(fifo.depth.stages), packed_count);
}

test "the receive count lands in RDC" {
    try testing.expectEqual(@as(u32, 0x0000_0300), fifo.receiveCount(3));
    try testing.expectEqual(@as(u32, 0), fifo.receiveCount(0));
}

test "an assert of both reset bits is an edge on both" {
    try testing.expectEqual(fifo.reset.both, fifo.asserted(0, fifo.reset.both));
}

test "a reset bit already set is not a fresh edge" {
    try testing.expectEqual(@as(u32, 0), fifo.asserted(fifo.reset.both, fifo.reset.both));
    try testing.expectEqual(
        fifo.reset.transmit,
        fifo.asserted(fifo.reset.receive, fifo.reset.both),
    );
}

test "bits outside the two resets are not an edge" {
    try testing.expectEqual(@as(u32, 0), fifo.asserted(0, 0xFFFF_FFFC));
}

test "clearing a reset bit is not an edge" {
    try testing.expectEqual(@as(u32, 0), fifo.asserted(fifo.reset.both, 0));
}
