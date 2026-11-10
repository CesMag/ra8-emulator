//! The terminology gate: the inclusive vocabulary ra8-firmware uses.
//!
//! Anything that drives the fabric is a bus initiator, SPI and I2C roles are
//! the controller and the peripheral, the select line is CS (chip select),
//! and the data lines are COPI and CIPO. This tool flags any line that still
//! uses the old words, which are spelled in halves below so this file passes
//! its own check.
const std = @import("std");

pub const banned = struct {
    /// Matched anywhere and in any case, since they hide inside identifiers
    /// (`asM...er`, `m..._ram`) as easily as in prose.
    pub const anywhere = [_][]const u8{ "mas" ++ "ter", "sla" ++ "ve" };
    /// Matched as whole words, exact case. An underscore splits words, so a
    /// pin name with a suffix is still caught.
    pub const words = [_][]const u8{ "MO" ++ "SI", "MI" ++ "SO" };
};

/// The file types the gate reads; anything else is data or a binary.
pub const scanned = [_][]const u8{ ".zig", ".zon", ".md", ".sh", ".py", ".txt", ".toml", ".yml", ".yaml", ".s", ".ld" };

/// The first banned word on `line`, or null when the line is clean.
pub fn firstBanned(line: []const u8) ?[]const u8 {
    for (banned.anywhere) |word| {
        if (std.ascii.findIgnoreCase(line, word) != null) return word;
    }
    for (banned.words) |word| {
        if (hasWord(line, word)) return word;
    }
    return null;
}

fn hasWord(line: []const u8, word: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, word)) |at| : (from = at + 1) {
        const end = at + word.len;
        const starts = at == 0 or !std.ascii.isAlphanumeric(line[at - 1]);
        const ends = end == line.len or !std.ascii.isAlphanumeric(line[end]);
        if (starts and ends) return true;
    }
    return false;
}

/// Whether the gate reads a file with this name.
pub fn isScanned(name: []const u8) bool {
    for (scanned) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return true;
    }
    return false;
}

/// Build output and caches are not ours to police.
fn isOutput(path: []const u8) bool {
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    while (parts.next()) |part| {
        if (part[0] == '.' or std.mem.eql(u8, part, "zig-out") or std.mem.eql(u8, part, "zig-pkg") or std.mem.eql(u8, part, "node_modules")) return true;
    }
    return false;
}

/// terms <path>...
///
/// A path is a file or a directory to walk. Every finding is printed; the
/// exit status is 1 when there was at least one.
pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    var buf: [4096]u8 = undefined;
    var err = std.Io.File.stderr().writer(init.io, &buf);
    var run: Run = .{ .alloc = alloc, .io = init.io, .out = &err.interface };
    const argv = try init.minimal.args.toSlice(alloc);
    for (argv[1..]) |path| try run.walk(path);
    if (run.scanned == 0) return error.NothingToCheck;
    if (run.findings > 0) {
        try run.out.print("terms: {d} lines with a banned word in {d} files\n", .{ run.findings, run.scanned });
        try run.out.flush();
        std.process.exit(1);
    }
    try run.out.print("terms: {d} files clean\n", .{run.scanned});
    try run.out.flush();
}

const Run = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    scanned: usize = 0,
    findings: usize = 0,

    fn walk(self: *Run, path: []const u8) !void {
        var dir = std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true }) catch |err| switch (err) {
            error.NotDir => return self.check(path),
            else => return err,
        };
        defer dir.close(self.io);
        var it = try dir.walk(self.alloc);
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .file or !isScanned(entry.basename) or isOutput(entry.path)) continue;
            try self.check(try std.fs.path.join(self.alloc, &.{ path, entry.path }));
        }
    }

    fn check(self: *Run, path: []const u8) !void {
        const text = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.alloc, .limited(16 << 20));
        self.scanned += 1;
        var lines = std.mem.splitScalar(u8, text, '\n');
        var number: usize = 0;
        while (lines.next()) |line| {
            number += 1;
            const word = firstBanned(line) orelse continue;
            self.findings += 1;
            try self.out.print("{s}:{d}: says \"{s}\"; see tools/terms.zig for the word to use\n", .{ path, number, word });
        }
    }
};
