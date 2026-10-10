//! Connection profiles for `ctl --host NAME` (RA8EMU-196): a hosts file
//! with one profile per line, where `#` starts a comment.
//!
//!   local NAME
//!   ssh NAME DESTINATION [emulator=PATH] [cache=DIR] [ssh=PROGRAM]
//!
//! The file is `--hosts FILE`, else $RA8_HOSTS, else
//! $HOME/.config/ra8_emulator/hosts.
const std = @import("std");

/// Largest hosts file read.
const max_file = 64 * 1024;

pub const Ssh = struct {
    /// What ssh is given as the host: `user@box`, or an alias from ~/.ssh/config.
    destination: []const u8,
    /// The emulator on the remote, found on its PATH unless given.
    emulator: []const u8 = "ra8_emulator",
    /// Where the remote keeps images by content hash: absolute, or relative
    /// to the remote home.
    cache: []const u8 = ".cache/ra8_emulator/images",
    /// The ssh program to run.
    program: []const u8 = "ssh",
};

pub const Profile = union(enum) { local, ssh: Ssh };

const Words = std.mem.TokenIterator(u8, .any);

/// The profile called `name` in the hosts file `text`.
pub fn find(text: []const u8, name: []const u8) !Profile {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const cut = std.mem.indexOfScalar(u8, raw, '#') orelse raw.len;
        var words = std.mem.tokenizeAny(u8, raw[0..cut], " \t\r");
        const kind = words.next() orelse continue;
        const named = words.next() orelse return error.BadHostsLine;
        if (std.mem.eql(u8, named, name)) return profile(kind, &words);
    }
    return error.UnknownHost;
}

fn profile(kind: []const u8, words: *Words) !Profile {
    if (std.mem.eql(u8, kind, "local")) return if (words.next() == null) .local else error.BadHostsLine;
    if (!std.mem.eql(u8, kind, "ssh")) return error.BadHostsLine;
    var ssh: Ssh = .{ .destination = words.next() orelse return error.BadHostsLine };
    while (words.next()) |word| {
        const eq = std.mem.indexOfScalar(u8, word, '=') orelse return error.BadHostsLine;
        const key = word[0..eq];
        const value = word[eq + 1 ..];
        if (value.len == 0) return error.BadHostsLine;
        if (std.mem.eql(u8, key, "emulator")) {
            ssh.emulator = value;
        } else if (std.mem.eql(u8, key, "cache")) {
            ssh.cache = value;
        } else if (std.mem.eql(u8, key, "ssh")) {
            ssh.program = value;
        } else return error.BadHostsLine;
    }
    return .{ .ssh = ssh };
}

/// The hosts file to read: `given`, else $RA8_HOSTS, else the one under $HOME.
pub fn path(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, given: ?[]const u8) ![]const u8 {
    if (given) |file| return file;
    if (env.get("RA8_HOSTS")) |file| return file;
    const home = env.get("HOME") orelse return error.NoHostsFile;
    return std.fs.path.join(allocator, &.{ home, ".config", "ra8_emulator", "hosts" });
}

/// Read the hosts file and return the profile called `name`. Slices point
/// into memory from `allocator`, which ctl runs as an arena.
pub fn load(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, given: ?[]const u8, name: []const u8) !Profile {
    const file = try path(allocator, env, given);
    const text = std.Io.Dir.cwd().readFileAlloc(io, file, allocator, .limited(max_file)) catch return error.NoHostsFile;
    return find(text, name);
}
