const std = @import("std");
const ra8 = @import("ra8");
const stop = ra8.chip.core.stop;

test "a counter below the floor is not a stop" {
    var watch = stop.Stop{ .address = 0x2200_0000, .reaches = 5 };
    try std.testing.expect(!watch.met(4));
    try std.testing.expect(!watch.reached);
}

test "a counter at the floor stops the run" {
    var watch = stop.Stop{ .address = 0x2200_0000, .reaches = 5 };
    try std.testing.expect(watch.met(5));
    try std.testing.expect(watch.reached);
}

test "a counter past the floor stops the run" {
    var watch = stop.Stop{ .address = 0x2200_0000, .reaches = 5 };
    try std.testing.expect(watch.met(9));
    try std.testing.expect(watch.reached);
}

test "a floor of zero is met by the first look" {
    var watch = stop.Stop{ .address = 0x2200_0000, .reaches = 0 };
    try std.testing.expect(watch.met(0));
    try std.testing.expect(watch.reached);
}

test "a word that will not read is not a stop" {
    var watch = stop.Stop{ .address = 0x2200_0000, .reaches = 0 };
    try std.testing.expect(!watch.met(null));
    try std.testing.expect(!watch.reached);
}

test "the reached flag stays up once the floor has been passed" {
    var watch = stop.Stop{ .address = 0x2200_0000, .reaches = 2 };
    try std.testing.expect(watch.met(2));
    try std.testing.expect(!watch.met(1));
    try std.testing.expect(watch.reached);
}
