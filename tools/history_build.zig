//! Provenance for frozen roots. Hash actual source bytes, including dirty
//! edits, rather than assigning an independent model version number.
const std = @import("std");

pub fn options(b: *std.Build) *std.Build.Step.Options {
    // Git refs and dirty sources can change without a build-script change.
    b.graph.poisonCache();
    const opts = b.addOptions();
    var commit: [20]u8 = @splat(0);
    switch (b.runFallible(&.{ "git", "-C", b.root.joinString(b.allocator, ".") catch @panic("OOM"), "rev-parse", "HEAD" }, .{ .stderr_behavior = .ignore })) {
        .success => |out| {
            const text = std.mem.trim(u8, out, "\r\n ");
            if (text.len == 40) _ = std.fmt.hexToBytes(&commit, text) catch @panic("invalid git commit");
        },
        else => {},
    }
    opts.addOption([20]u8, "commit", commit);
    opts.addOption([]const u8, "model", fingerprint(b) catch @panic("cannot fingerprint history model"));
    return opts;
}

fn fingerprint(b: *std.Build) ![]const u8 {
    const io = b.graph.io;
    const gpa = b.allocator;
    const dir = try b.root.openDir(io, "src", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    var names: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const path = try gpa.dupe(u8, entry.path);
        // Normalize before sorting too: separators otherwise change the
        // relative order of a directory and a similarly named file.
        for (path) |*c| if (c.* == '\\') {
            c.* = '/';
        };
        try names.append(gpa, path);
    }
    std.mem.sort([]const u8, names.items, {}, less);
    var hash = std.crypto.hash.Blake3.init(.{});
    hash.update(@import("builtin").zig_version_string);
    for (names.items) |path| {
        const bytes = try dir.readFileAlloc(io, path, gpa, .unlimited);
        hash.update(path);
        hash.update(&.{0});
        hash.update(bytes);
        hash.update(&.{0});
    }
    for ([_][]const u8{ "build.zig", "build_tests.zig", "build.zig.zon", "tools/history_build.zig" }) |path| {
        hash.update(try std.Io.Dir.cwd().readFileAlloc(io, try b.root.joinString(gpa, path), gpa, .unlimited));
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return gpa.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
}

fn less(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
