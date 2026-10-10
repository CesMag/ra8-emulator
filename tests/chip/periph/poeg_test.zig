//! Covers src/chip/periph/poeg.zig.
const std = @import("std");
const poeg = @import("ra8").chip.periph.poeg;

const g0 = poeg.groupAddress(0);
const g1 = poeg.groupAddress(1);

fn unit() poeg.Poeg {
    return poeg.Poeg.init();
}

test "a fresh group drives its outputs" {
    var block = unit();
    try std.testing.expectEqual(@as(u32, 0), block.read(g0, 4));
    try std.testing.expect(!block.groups[0].disabled());
    try std.testing.expect(block.quiet());
}

test "a software stop asserts ST and reads back" {
    var block = unit();
    block.write(g0, 4, poeg.field.ssf);
    try std.testing.expectEqual(poeg.field.ssf | poeg.field.st, block.read(g0, 4));
    try std.testing.expectEqual(@as(u32, 1), block.groups[0].asserts);
}

test "clearing the software stop re-enables the outputs" {
    var block = unit();
    block.write(g0, 4, poeg.field.ssf);
    block.write(g0, 4, 0);
    try std.testing.expectEqual(@as(u32, 0), block.read(g0, 4));
    try std.testing.expectEqual(@as(u32, 1), block.groups[0].clears);
}

test "ST is read-only: writing it alone disables nothing" {
    var block = unit();
    block.write(g0, 4, poeg.field.st);
    try std.testing.expectEqual(@as(u32, 0), block.read(g0, 4));
    try std.testing.expectEqual(@as(u32, 0), block.groups[0].asserts);
}

test "firmware cannot fake a pin-fault shutoff" {
    var block = unit();
    block.write(g0, 4, poeg.field.pidf);
    try std.testing.expectEqual(@as(u32, 0), block.read(g0, 4));
    try std.testing.expectEqual(@as(u32, 1), block.groups[0].faked);
    try std.testing.expectEqual(@as(u32, 0), block.groups[0].asserts);
}

test "all three external flags at once are all refused, and all counted" {
    var block = unit();
    block.write(g0, 4, poeg.field.external);
    try std.testing.expectEqual(@as(u32, 0), block.read(g0, 4));
    try std.testing.expectEqual(@as(u32, 3), block.groups[0].faked);
}

test "a trigger source raises a request the firmware could not" {
    var block = unit();
    block.trigger(0, .pin);
    try std.testing.expectEqual(poeg.field.pidf | poeg.field.st, block.read(g0, 4));
    try std.testing.expectEqual(@as(u32, 1), block.groups[0].asserts);
}

test "a latched trigger is cleared by writing zero to it" {
    var block = unit();
    block.trigger(0, .output_short);
    block.write(g0, 4, 0);
    try std.testing.expectEqual(@as(u32, 0), block.read(g0, 4));
    try std.testing.expectEqual(@as(u32, 1), block.groups[0].clears);
}

test "a latched trigger survives a write that only clears SSF" {
    var block = unit();
    block.trigger(0, .oscillation_stop);
    block.write(g0, 4, poeg.field.ostpf);
    try std.testing.expectEqual(poeg.field.ostpf | poeg.field.st, block.read(g0, 4));
    try std.testing.expectEqual(@as(u32, 0), block.groups[0].clears);
}

test "the outputs stay disabled while any one request is still up" {
    var block = unit();
    block.trigger(0, .pin);
    block.write(g0, 4, poeg.field.pidf | poeg.field.ssf);
    block.write(g0, 4, poeg.field.pidf);
    try std.testing.expect(block.groups[0].disabled());
    try std.testing.expectEqual(@as(u32, 1), block.groups[0].asserts);
    try std.testing.expectEqual(@as(u32, 0), block.groups[0].clears);
}

test "re-asserting a request already up is not a second shutoff" {
    var block = unit();
    block.write(g0, 4, poeg.field.ssf);
    block.write(g0, 4, poeg.field.ssf);
    try std.testing.expectEqual(@as(u32, 1), block.groups[0].asserts);
}

test "a byte store to the low byte asserts SSF" {
    var block = unit();
    block.write(g0, 1, poeg.field.ssf);
    try std.testing.expectEqual(poeg.field.ssf | poeg.field.st, block.read(g0, 4));
}

test "a byte store leaves the bytes it does not name alone" {
    var block = unit();
    block.write(g0 + 3, 1, 0xA5);
    block.write(g0, 1, poeg.field.ssf);
    try std.testing.expectEqual(@as(u32, 0xA5), block.read(g0 + 3, 1));
    try std.testing.expect(block.groups[0].disabled());
}

test "a halfword store to the ST half cannot disable the outputs" {
    var block = unit();
    block.write(g0 + 2, 2, 1);
    try std.testing.expect(!block.groups[0].disabled());
}

test "a narrow read names one byte of POEGG" {
    var block = unit();
    block.write(g0, 4, poeg.field.ssf);
    try std.testing.expectEqual(poeg.field.ssf, block.read(g0, 1));
    try std.testing.expectEqual(@as(u32, 1), block.read(g0 + 2, 1));
}

test "groups are independent" {
    var block = unit();
    block.write(g1, 4, poeg.field.ssf);
    try std.testing.expect(block.groups[1].disabled());
    try std.testing.expect(!block.groups[0].disabled());
    try std.testing.expectEqual(@as(u32, 0), block.read(g0, 4));
}

test "an address past the last group answers nothing" {
    var block = unit();
    const past = poeg.win_base + poeg.win_span;
    block.write(past, 4, poeg.field.ssf);
    try std.testing.expectEqual(@as(u32, 0), block.read(past, 4));
    try std.testing.expect(block.quiet());
}

test "the rest of the group window is shadowed, not dropped" {
    var block = unit();
    block.write(g0 + 0x20, 4, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), block.read(g0 + 0x20, 4));
    try std.testing.expectEqual(@as(u32, 1), block.groups[0].shadow_writes);
}

test "a shadowed write is not a shutoff" {
    var block = unit();
    block.write(g0 + 0x20, 4, poeg.field.requests);
    try std.testing.expect(!block.groups[0].disabled());
    try std.testing.expect(block.quiet());
}

test "trigger declines a group that does not exist" {
    var block = unit();
    block.trigger(poeg.group_count, .pin);
    try std.testing.expect(block.quiet());
}

test "the block descriptor covers all four groups" {
    var block = unit();
    const descriptor = block.block();
    try std.testing.expectEqual(poeg.win_base, descriptor.base);
    try std.testing.expectEqual(@as(u32, 0x400), descriptor.size);
}

test "the descriptor thunks reach the same state as the methods" {
    var block = unit();
    const descriptor = block.block();
    descriptor.writeFn(descriptor.context, g0, 4, poeg.field.ssf);
    try std.testing.expectEqual(
        poeg.field.ssf | poeg.field.st,
        descriptor.readFn(descriptor.context, g0, 4),
    );
}

test "a byte store to SSF keeps the uninterpreted upper bits" {
    var block = unit();
    block.write(g1, 4, 0x3000_0000);
    block.write(g1, 1, poeg.field.ssf);
    try std.testing.expectEqual(
        @as(u32, 0x3000_0008 | poeg.field.st),
        block.read(g1, 4),
    );
}
