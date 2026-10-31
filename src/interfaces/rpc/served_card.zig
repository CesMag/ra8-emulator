//! Host startup card inputs shared by the CLI and GUI adapters.
const std = @import("std");
const Board = @import("ra8_board").board.Board;
const host_folder = @import("ra8_host").folder;
const card_apps = @import("card_apps.zig");
const default_label = "RA8";

pub const Options = struct {
    image: ?[]const u8 = null,
    /// `--sd-dir DIR`: a FAT32 image built from DIR (RA8EMU-563) instead.
    dir: ?[]const u8 = null,
    writable: bool = false,
    /// `--app FILE.ra8app`, repeatable (RA8EMU-1138): files for the card's root.
    apps: [card_apps.max_apps][]const u8 = undefined,
    app_count: u8 = 0,

    pub fn addApp(self: *Options, path: []const u8) !void {
        if (self.app_count == card_apps.max_apps) return error.TooManyApps;
        self.apps[self.app_count] = path;
        self.app_count += 1;
    }

    pub fn appPaths(self: *const Options) []const []const u8 {
        return self.apps[0..self.app_count];
    }
};

/// Load the `--sd-image` file into the SDHI card.
pub fn prepare(board: *Board, io: std.Io, sdhi: Options) !void {
    if (sdhi.dir != null or sdhi.app_count > 0) {
        if (sdhi.image != null) {
            const what = if (sdhi.dir != null) "--sd-dir" else "--app";
            std.debug.print("{s} and --sd-image both name the SDHI card; pick one\n", .{what});
            return error.ConflictingCardOptions;
        }
        return fromDir(board, io, sdhi);
    }
    const path = sdhi.image orelse return;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, std.heap.page_allocator, .unlimited) catch |err| {
        std.debug.print("cannot read SD image {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer std.heap.page_allocator.free(bytes);
    board.host_card.loadBytes(bytes) catch |err| {
        std.debug.print("--sd-image {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
}

/// Build the card image from the `--sd-dir` folder and any `--app` files,
/// and hand its bytes to the SDHI card.
fn fromDir(board: *Board, io: std.Io, sdhi: Options) !void {
    const allocator = std.heap.page_allocator;
    var staged: [card_apps.max_apps]card_apps.Staged = undefined;
    const apps = try card_apps.load(io, allocator, sdhi.appPaths(), &staged);
    defer card_apps.unload(allocator, apps);
    var root: card_apps.Root = .{ .base = null, .apps = apps };
    if (sdhi.dir) |path| root.base = host_folder.Folder.open(io, path) catch |err| {
        std.debug.print("--sd-dir {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer root.close();
    const source = sdhi.dir orelse "--app";
    const built = card_apps.buildCard(board, allocator, root, default_label) catch |err| {
        std.debug.print("--sd-dir {s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    std.debug.print("sd-dir: {s} -> FAT32 {d} MiB, {d} files, {d} dirs\n", .{ source, built.blocks / 2048, built.files, built.dirs });
}

/// Own module bytes and pairs for as long as the harness borrows them.
pub fn stage(self: anytype, options: Options) !void {
    try prepare(self.owner.board(), self.io, options);
    if (options.app_count == 0) return;
    const arena = try self.gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(self.gpa);
    errdefer self.gpa.destroy(arena);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    const staged = try allocator.alloc(card_apps.Staged, card_apps.max_apps);
    const apps = try card_apps.paired(self.io, allocator, options.appPaths(), staged);
    const pairs = try allocator.create([card_apps.max_apps]@import("ra8_session").txm.debug.Pair);
    const paired = try card_apps.pairs(apps, pairs);
    release(self);
    self.card_arena = arena;
    self.pairModules(paired);
}

pub fn release(self: anytype) void {
    if (self.card_arena) |arena| {
        arena.deinit();
        self.gpa.destroy(arena);
        self.card_arena = null;
    }
}
