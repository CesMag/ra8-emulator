//! RA8EMU-794: `ctl map` against a spawned `serve --listen`. The map
//! follows the image the session last loaded, its text is exactly what
//! `--map` prints, and its JSON carries the same numbers.
const std = @import("std");
const test_paths = @import("test_paths");
const serve_peer = @import("serve_peer.zig");
const ctl_run = @import("ctl_run.zig");
const Term = std.process.Child.Term;
const Value = std.json.Value;

const sections_image = "tests/fixtures/sections/fault_crashlog_hil.elf";

fn region(regions: Value, name: []const u8) ?Value {
    for (regions.array.items) |item| {
        if (std.mem.eql(u8, item.object.get("name").?.string, name)) return item;
    }
    return null;
}

fn used(regions: Value, name: []const u8) !i64 {
    return ctl_run.expectInteger(region(regions, name).?.object.get("used").?);
}

/// How many of a region's sections carry this name and copy.
fn listed(regions: Value, name: []const u8, section: []const u8, copy: []const u8) usize {
    var found: usize = 0;
    for (region(regions, name).?.object.get("sections").?.array.items) |item| {
        const named = std.mem.eql(u8, item.object.get("name").?.string, section);
        if (named and std.mem.eql(u8, item.object.get("copy").?.string, copy)) found += 1;
    }
    return found;
}

fn stdoutOf(gpa: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(gpa, std.testing.io, .{ .argv = argv, .stdout_limit = .limited(1 << 20) });
    defer gpa.free(result.stderr);
    errdefer gpa.free(result.stdout);
    try std.testing.expectEqual(Term{ .exited = 0 }, result.term);
    return result.stdout;
}

test "ctl map follows the last loaded image, prints what --map prints, and carries the same numbers as JSON" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/map.sock", .{tmp.sub_path});
    defer gpa.free(path);
    const spec = try std.fmt.allocPrint(gpa, "unix:{s}", .{path});
    defer gpa.free(spec);
    var line: [256]u8 = undefined;
    var served = try serve_peer.listen(spec, &line);
    defer served.child.kill(std.testing.io);

    var loaded = try ctl_run.run(gpa, spec, &.{ "load", sections_image });
    defer loaded.deinit();
    try std.testing.expectEqual(Term{ .exited = 0 }, loaded.term);

    var answer = try ctl_run.run(gpa, spec, &.{"map"});
    defer answer.deinit();
    try std.testing.expectEqual(Term{ .exited = 0 }, answer.term);
    const regions = answer.field("map").object.get("regions").?;
    try std.testing.expectEqual(@as(i64, 0x3454), try used(regions, "MRAM"));
    try std.testing.expectEqual(@as(i64, 0xb78), try used(regions, "SRAM"));
    try std.testing.expectEqual(@as(i64, 0x5c), try used(regions, "NOINIT"));
    try std.testing.expectEqual(@as(usize, 1), listed(regions, "MRAM", ".data", "load"));
    try std.testing.expectEqual(@as(usize, 1), listed(regions, "SRAM", ".data", "run"));
    const stack = answer.field("map").object.get("stack").?.object;
    try std.testing.expectEqual(@as(i64, 0x2000), try ctl_run.expectInteger(stack.get("size").?));
    try std.testing.expectEqualStrings("SRAM", stack.get("region").?.string);

    const text = try stdoutOf(gpa, &.{ test_paths.emulator, "ctl", "--connect", spec, "map" });
    defer gpa.free(text);
    const direct = try stdoutOf(gpa, &.{ test_paths.emulator, "--map", sections_image });
    defer gpa.free(direct);
    try std.testing.expectEqualStrings(direct, text);
}

test "ctl map before any load maps the image serve was opened with" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/open.sock", .{tmp.sub_path});
    defer gpa.free(path);
    const spec = try std.fmt.allocPrint(gpa, "unix:{s}", .{path});
    defer gpa.free(spec);
    var line: [256]u8 = undefined;
    var served = try serve_peer.listen(spec, &line);
    defer served.child.kill(std.testing.io);

    const text = try stdoutOf(gpa, &.{ test_paths.emulator, "ctl", "--connect", spec, "map" });
    defer gpa.free(text);
    const direct = try stdoutOf(gpa, &.{ test_paths.emulator, "--map", serve_peer.image_path });
    defer gpa.free(direct);
    try std.testing.expectEqualStrings(direct, text);
}
