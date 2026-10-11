//! `--app FILE.ra8app` (RA8EMU-1138): ThreadX module apps for the SDHI card.
//!
//! An app reaches the board the way it does on hardware: as a file in the
//! card's root that ra8-firmware's loader reads, verifies and hands to the
//! Module Manager (txm_sd_hello_m85). The emulator only admits each app's
//! header against the firmware's rules before boot, so a malformed app is
//! refused with the same error the loader would name instead of after a
//! boot; the signature stays the firmware's check. Root lays the admitted
//! apps beside the `--sd-dir` folder's own entries for the card builder.
const std = @import("std");
const ra8app = @import("ra8_board").image.ra8app;
const host_folder = @import("ra8_host").folder;

/// The most `--app` flags one run takes.
pub const max_apps = 8;

/// An admitted app: the name it takes in the card's root and its bytes.
pub const Staged = struct { name: []const u8, bytes: []const u8 };

/// Read each app, admit its header, and fill `out`; free with `unload`.
/// A file that can't be read or isn't admitted is reported by path.
pub fn load(io: std.Io, allocator: std.mem.Allocator, paths: []const []const u8, out: []Staged) ![]Staged {
    var count: usize = 0;
    errdefer unload(allocator, out[0..count]);
    for (paths) |path| {
        out[count] = try loadOne(io, allocator, path);
        count += 1;
    }
    return out[0..count];
}

fn loadOne(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Staged {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(std.math.maxInt(u32))) catch |err| {
        std.debug.print("--app {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    errdefer allocator.free(bytes);
    const header = ra8app.parse(bytes) catch |err| {
        std.debug.print("--app {s}: refused, {s}\n", .{ path, @errorName(err) });
        return err;
    };
    const name = std.fs.path.basename(path);
    std.debug.print("app: {s} ({s}, \"{s}\") -> card root\n", .{ name, header.id(), header.name() });
    return .{ .name = name, .bytes = bytes };
}

pub fn unload(allocator: std.mem.Allocator, apps: []const Staged) void {
    for (apps) |app| allocator.free(app.bytes);
}

/// The card's root as the builder reads it: the `--sd-dir` folder, when
/// there is one, with the apps added as files. An app whose name the folder
/// already has is refused rather than either copy quietly winning.
pub const Root = struct {
    base: ?host_folder.Folder,
    apps: []const Staged,

    pub fn close(self: *Root) void {
        if (self.base) |*base| base.close();
    }

    pub fn list(self: Root, allocator: std.mem.Allocator) ![]host_folder.Entry {
        var entries: std.ArrayList(host_folder.Entry) = if (self.base) |base| .fromOwnedSlice(try base.list(allocator)) else .empty;
        errdefer {
            for (entries.items) |entry| allocator.free(entry.name);
            entries.deinit(allocator);
        }
        for (self.apps) |app| {
            for (entries.items) |entry| {
                if (std.mem.eql(u8, entry.name, app.name)) return error.AppNameTaken;
            }
            const name = try allocator.dupe(u8, app.name);
            errdefer allocator.free(name);
            try entries.append(allocator, .{ .name = name, .kind = .file });
        }
        return entries.toOwnedSlice(allocator);
    }

    pub fn free(allocator: std.mem.Allocator, entries: []host_folder.Entry) void {
        host_folder.Folder.free(allocator, entries);
    }

    /// A subfolder of the `--sd-dir` folder; apps sit only in the root.
    pub fn sub(self: Root, name: []const u8) !host_folder.Folder {
        const base = self.base orelse return error.FileNotFound;
        return base.sub(name);
    }

    pub fn size(self: Root, name: []const u8) !u64 {
        if (self.find(name)) |app| return app.bytes.len;
        const base = self.base orelse return error.FileNotFound;
        return base.size(name);
    }

    pub fn read(self: Root, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        if (self.find(name)) |app| return allocator.dupe(u8, app.bytes);
        const base = self.base orelse return error.FileNotFound;
        return base.read(allocator, name);
    }

    fn find(self: Root, name: []const u8) ?Staged {
        for (self.apps) |app| {
            if (std.mem.eql(u8, app.name, name)) return app;
        }
        return null;
    }
};
