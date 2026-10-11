const std = @import("std");
const ra8 = @import("ra8");
const place = ra8.session.place;

test "a bare hex address is a literal base" {
    const found = try place.parse("0x22000058");
    try std.testing.expect(found.name == null);
    try std.testing.expectEqual(@as(u32, 0x22000058), found.address);
    try std.testing.expect(!found.deref);
    try std.testing.expectEqual(@as(i32, 0), found.offset);
}

test "a decimal address is a literal base too" {
    const found = try place.parse("1024");
    try std.testing.expect(found.name == null);
    try std.testing.expectEqual(@as(u32, 1024), found.address);
}

test "anything that is not a number is a symbol name" {
    const found = try place.parse("g_eoh_err");
    try std.testing.expect(found.name != null);
    try std.testing.expectEqualStrings("g_eoh_err", found.name.?);
    try std.testing.expectEqual(@as(u32, 0), found.address);
}

test "a leading at sign asks for one dereference" {
    const found = try place.parse("@s_open");
    try std.testing.expect(found.deref);
    try std.testing.expectEqualStrings("s_open", found.name.?);
}

test "an offset is taken off the end and the name keeps the rest" {
    const found = try place.parse("@s_open+0x40");
    try std.testing.expect(found.deref);
    try std.testing.expectEqualStrings("s_open", found.name.?);
    try std.testing.expectEqual(@as(i32, 0x40), found.offset);
}

test "a negative offset parses as one" {
    const found = try place.parse("0x22000100-8");
    try std.testing.expectEqual(@as(u32, 0x22000100), found.address);
    try std.testing.expectEqual(@as(i32, -8), found.offset);
}

test "an offset applies after the base, wrapping rather than trapping" {
    const found = try place.parse("@m+0x40");
    try std.testing.expectEqual(@as(u32, 0x220010A0), found.apply(0x22001060));
    const back = try place.parse("x-16");
    try std.testing.expectEqual(@as(u32, 0xFFFFFFF0), back.apply(0));
}

test "a place with nothing to it is refused" {
    try std.testing.expectError(error.EmptyPlace, place.parse(""));
    try std.testing.expectError(error.EmptyPlace, place.parse("@"));
}

test "an offset that is not a number is refused" {
    try std.testing.expectError(error.BadOffset, place.parse("s_open+zz"));
}

test "the word count falls back to the default and is capped" {
    try std.testing.expectEqual(place.limits.default_words, place.words(null));
    try std.testing.expectEqual(@as(u32, 7), place.words(7));
    try std.testing.expectEqual(place.limits.max_words, place.words(1000));
}

test "lines open every fourth word and close on the fourth or the last" {
    try std.testing.expect(place.startsLine(0));
    try std.testing.expect(!place.startsLine(1));
    try std.testing.expect(place.startsLine(4));
    try std.testing.expect(place.endsLine(3, 8));
    try std.testing.expect(!place.endsLine(1, 8));
    try std.testing.expect(place.endsLine(5, 6));
}

test "a leading star is gdb's address spelling and changes nothing" {
    const literal = try place.parse("*0x2200005E");
    try std.testing.expect(literal.name == null);
    try std.testing.expectEqual(@as(u32, 0x2200005E), literal.address);
    try std.testing.expect(!literal.deref);
    const named = try place.parse("*main+4");
    try std.testing.expectEqualStrings("main", named.name.?);
    try std.testing.expectEqual(@as(i32, 4), named.offset);
    try std.testing.expect(!named.deref);
}

test "a star with nothing after it is an empty place" {
    try std.testing.expectError(error.EmptyPlace, place.parse("*"));
}
