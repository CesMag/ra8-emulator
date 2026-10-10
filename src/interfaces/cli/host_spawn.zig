//! Starting `serve --stdio` for a host profile (RA8EMU-196). A local
//! profile runs this emulator. An ssh profile runs the remote's, after
//! copying the image into the remote cache under its SHA-256, which is
//! skipped when the remote already holds that file.
const std = @import("std");
const profiles = @import("ra8_host").profiles;

/// Largest image ctl copies to a remote.
const max_image = 64 * 1024 * 1024;

/// The argv that starts `serve --stdio` for the image at `image_path` on
/// `profile`. Memory comes from `allocator`, which ctl runs as an arena.
pub fn serveArgv(allocator: std.mem.Allocator, io: std.Io, profile: profiles.Profile, image_path: []const u8) ![]const []const u8 {
    switch (profile) {
        .local => {
            const exe = try std.process.executablePathAlloc(io, allocator);
            return allocator.dupe([]const u8, &.{ exe, "serve", "--stdio", image_path });
        },
        .ssh => |ssh| {
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, image_path, allocator, .limited(max_image)) catch return error.ImageUnreadable;
            const remote = try cachePath(allocator, ssh.cache, bytes);
            try ensureCopied(allocator, io, ssh, remote, bytes);
            const line = try std.fmt.allocPrint(allocator, "{s} serve --stdio {s}", .{ try quote(allocator, ssh.emulator), try quote(allocator, remote) });
            return allocator.dupe([]const u8, &.{ ssh.program, "-T", ssh.destination, line });
        },
    }
}

/// `cache/<sha256 of bytes>.elf`.
pub fn cachePath(allocator: std.mem.Allocator, cache: []const u8, bytes: []const u8) ![]const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.allocPrint(allocator, "{s}/{x}.elf", .{ cache, &digest });
}

/// Copy `bytes` to `remote` unless a `test -f` there says it is present.
/// ssh exits 255 for its own failures, which is reported as unreachable.
fn ensureCopied(allocator: std.mem.Allocator, io: std.Io, ssh: profiles.Ssh, remote: []const u8, bytes: []const u8) !void {
    const file = try quote(allocator, remote);
    const probe = try std.fmt.allocPrint(allocator, "test -f {s}", .{file});
    const held = try std.process.run(allocator, io, .{ .argv = &.{ ssh.program, "-T", ssh.destination, probe } });
    switch (held.term) {
        .exited => |code| switch (code) {
            0 => return,
            1 => {},
            else => return error.HostUnreachable,
        },
        else => return error.HostUnreachable,
    }
    const dir = try quote(allocator, ssh.cache);
    const store = try std.fmt.allocPrint(allocator, "mkdir -p {s} && cat > {s}.part && mv {s}.part {s}", .{ dir, file, file, file });
    var child = try std.process.spawn(io, .{ .argv = &.{ ssh.program, "-T", ssh.destination, store }, .stdin = .pipe });
    child.stdin.?.writeStreamingAll(io, bytes) catch {};
    child.stdin.?.close(io);
    child.stdin = null;
    if (!exitedClean(try child.wait(io))) return error.CopyFailed;
}

fn exitedClean(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// `text` single-quoted for the remote shell.
pub fn quote(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (text) |c| {
        if (c == '\'') try out.appendSlice(allocator, "'\\''") else try out.append(allocator, c);
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}
