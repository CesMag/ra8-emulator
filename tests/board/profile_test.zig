const std = @import("std");
const ra8 = @import("ra8");

test "versioned profiles parse sensor and companion endpoints" {
    const profile = try ra8.board.profile.parse(
        "version=1\nsensor=max17048@i2c:riic@0x37\ncompanion=c6@uart:sci2\n",
    );
    try std.testing.expectEqual(@as(usize, 2), profile.count);
    try std.testing.expectEqualStrings("max17048", profile.fits[0].name);
    try std.testing.expectEqualStrings("c6", profile.fits[1].name);
    try std.testing.expect(profile.fits[1].at == .uart);
    try std.testing.expectEqual(@as(u4, 2), profile.fits[1].at.uart.channel);
    try std.testing.expectEqual(@as(u32, 256 * 1024 * 1024), profile.memory.ospi.size);
}

test "profiles reject unsupported versions and malformed fitted models" {
    try std.testing.expectError(error.BadVersion, ra8.board.profile.parse("version=2\n"));
    try std.testing.expectError(error.UnknownModel, ra8.board.profile.parse("version=1\nsensor=missing@uart:sci1\n"));
}

test "profiles parse controller-supported external memory" {
    const profile = try ra8.board.profile.parse(
        "version=1\nospi=size:67108864,width:4,clock_hz:80000000,latency_cycles:6,burst:single\nsdram=size:33554432,width:16,clock_hz:66500000,latency_cycles:2,burst:incrementing16\nmemory_window_cycles=5000\n",
    );
    try std.testing.expectEqual(@as(u32, 67_108_864), profile.memory.ospi.size);
    try std.testing.expectEqual(@as(u8, 4), profile.memory.ospi.width);
    try std.testing.expectEqual(ra8.board.external.memory.Burst.single, profile.memory.ospi.burst);
    try std.testing.expectEqual(@as(u32, 33_554_432), profile.memory.sdram.size);
    try std.testing.expectEqual(@as(u32, 5000), profile.memory.window_cycles);
}

test "profiles reject malformed and impossible external memory" {
    try std.testing.expectError(error.BadMemory, ra8.board.profile.parse("version=1\nospi=size:1048576,width:8\n"));
    try std.testing.expectError(error.DuplicateMemory, ra8.board.profile.parse("version=1\nmemory_window_cycles=1\nmemory_window_cycles=2\n"));
    try std.testing.expectError(error.BadWidth, ra8.board.profile.parse("version=1\nsdram=size:1048576,width:4,clock_hz:1,latency_cycles:1,burst:single\n"));
    try std.testing.expectError(error.BadSize, ra8.board.profile.parse("version=1\nospi=size:3145728,width:8,clock_hz:1,latency_cycles:1,burst:single\n"));
    try std.testing.expectError(error.BadClock, ra8.board.profile.parse("version=1\nsdram=size:1048576,width:32,clock_hz:133000001,latency_cycles:1,burst:single\n"));
    try std.testing.expectError(error.BadLatency, ra8.board.profile.parse("version=1\nsdram=size:1048576,width:32,clock_hz:1,latency_cycles:0,burst:single\n"));
    try std.testing.expectError(error.BadWindow, ra8.board.profile.parse("version=1\nmemory_window_cycles=0\n"));
}
