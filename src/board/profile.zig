//! Versioned board composition files: fitted devices and external memory.
const std = @import("std");
const request = @import("ra8_components").request;
const external = @import("external/memory.zig");

pub const max_fits: usize = 4;

/// The shipped EK-RA8D2 profile, the board a run gets when it names none.
pub const ek_ra8d2 = @embedFile("ek_ra8d2.board");
pub const Profile = struct {
    fits: [max_fits]request.Request = undefined,
    count: usize = 0,
    memory: external.Config = .{},
};

pub const Error = error{
    BadVersion,
    BadEntry,
    TooManyFits,
    BadMemory,
    DuplicateMemory,
} || request.Error || external.Error;

/// Read the stable version-1 profile. Memory keys are optional so existing
/// profiles retain the generous defaults; unknown and duplicate keys fail
/// closed rather than silently selecting a different board.
pub fn parse(text: []const u8) Error!Profile {
    var result: Profile = .{};
    var has_version = false;
    var has_ospi = false;
    var has_sdram = false;
    var has_window = false;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "version=")) {
            if (has_version or !std.mem.eql(u8, line["version=".len..], "1")) return Error.BadVersion;
            has_version = true;
        } else if (std.mem.startsWith(u8, line, "ospi=")) {
            if (has_ospi) return Error.DuplicateMemory;
            result.memory.ospi = try parseRegion(line["ospi=".len..]);
            has_ospi = true;
        } else if (std.mem.startsWith(u8, line, "sdram=")) {
            if (has_sdram) return Error.DuplicateMemory;
            result.memory.sdram = try parseRegion(line["sdram=".len..]);
            has_sdram = true;
        } else if (std.mem.startsWith(u8, line, "memory_window_cycles=")) {
            if (has_window) return Error.DuplicateMemory;
            result.memory.window_cycles = std.fmt.parseInt(u32, line["memory_window_cycles=".len..], 10) catch return Error.BadMemory;
            has_window = true;
        } else if (std.mem.startsWith(u8, line, "sensor=")) {
            try addFit(&result, line["sensor=".len..]);
        } else if (std.mem.startsWith(u8, line, "companion=")) {
            try addFit(&result, line["companion=".len..]);
        } else return Error.BadEntry;
    }
    if (!has_version) return Error.BadVersion;
    try result.memory.validate();
    return result;
}

fn addFit(profile: *Profile, entry: []const u8) Error!void {
    if (profile.count == profile.fits.len) return Error.TooManyFits;
    profile.fits[profile.count] = try request.parse(entry);
    profile.count += 1;
}

fn parseRegion(text: []const u8) Error!external.RegionConfig {
    const names = [_][]const u8{ "size:", "width:", "clock_hz:", "latency_cycles:", "burst:" };
    var values: [names.len][]const u8 = undefined;
    var fields = std.mem.splitScalar(u8, text, ',');
    for (names, 0..) |name, index| {
        const field = fields.next() orelse return Error.BadMemory;
        if (!std.mem.startsWith(u8, field, name) or field.len == name.len) return Error.BadMemory;
        values[index] = field[name.len..];
    }
    if (fields.next() != null) return Error.BadMemory;
    return .{
        .size = std.fmt.parseInt(u32, values[0], 10) catch return Error.BadMemory,
        .width = std.fmt.parseInt(u8, values[1], 10) catch return Error.BadMemory,
        .clock_hz = std.fmt.parseInt(u32, values[2], 10) catch return Error.BadMemory,
        .latency_cycles = std.fmt.parseInt(u8, values[3], 10) catch return Error.BadMemory,
        .burst = external.Burst.parse(values[4]) orelse return Error.BadMemory,
    };
}
