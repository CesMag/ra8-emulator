//! Fit the CLI's SD card options onto the board's card.
const std = @import("std");
const Board = @import("../../board/board.zig").Board;
const sd_format = @import("../../components/sd_card/format.zig");
const sd_advice = @import("../../components/sd_card/format_advice.zig");
const sd_image = @import("../../components/sd_card/image.zig");
const sd_mkimage = @import("../../components/sd_card/mkimage.zig");
const disk_file = @import("ra8_host").disk_file;
const host_folder = @import("ra8_host").folder;

/// The label a `--sd-new` format gives the card when the spec names none.
pub const default_label = "RA8";

/// The format and label a `--sd-new FS[:LABEL]` spec asks for.
pub fn newSpec(spec: []const u8) !struct { sd_format.Kind, []const u8 } {
    const split = std.mem.indexOfScalar(u8, spec, ':') orelse spec.len;
    const kind = sd_format.Kind.parse(spec[0..split]) orelse return error.UnknownFormat;
    return .{ kind, if (split < spec.len) spec[split + 1 ..] else default_label };
}

/// `--sd-image PATH` backs the SDHI card with a raw host image; the card's
/// RAM store is the overlay, written back over PATH only with `--sd-writable`.
pub const Sdhi = struct {
    image: ?[]const u8 = null,
    /// `--sd-dir DIR`: a FAT32 image built from DIR (RA8EMU-563) instead.
    dir: ?[]const u8 = null,
    writable: bool = false,
};

/// Load the `--sd-image` file into the SDHI card.
pub fn prepareSdhi(board: *Board, io: std.Io, sdhi: Sdhi) !void {
    if (sdhi.dir) |dir| {
        if (sdhi.image != null) {
            std.debug.print("--sd-dir and --sd-image both name the SDHI card; pick one\n", .{});
            return error.ConflictingCardOptions;
        }
        return fromDir(board, io, dir);
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

/// Build the `--sd-dir` image and hand its bytes to the SDHI card.
fn fromDir(board: *Board, io: std.Io, path: []const u8) !void {
    const allocator = std.heap.page_allocator;
    var folder = host_folder.Folder.open(io, path) catch |err| {
        std.debug.print("--sd-dir {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer folder.close();
    var img = sd_image.Image.init(allocator);
    defer img.deinit();
    const built = sd_mkimage.build(allocator, &img, folder, default_label) catch |err| {
        std.debug.print("--sd-dir {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    const bytes = try allocator.alloc(u8, @as(usize, img.capacity_blocks) * 512);
    defer allocator.free(bytes);
    var index: u32 = 0;
    while (index < img.capacity_blocks) : (index += 1) {
        _ = img.read(index, bytes[@as(usize, index) * 512 ..][0..512]);
    }
    try board.host_card.loadBytes(bytes);
    std.debug.print("sd-dir: {s} -> FAT32 {d} MiB, {d} files, {d} dirs\n", .{ path, img.capacity_blocks / 2048, built.files, built.dirs });
}

/// Write the SDHI card back over its image when `--sd-writable` asked.
pub fn saveSdhi(board: *Board, io: std.Io, sdhi: Sdhi) void {
    if (!sdhi.writable) return;
    const path = sdhi.image orelse return;
    disk_file.replace(io, std.Io.Dir.cwd(), path, &board.host_card) catch |err| {
        std.debug.print("--sd-image {s}: not saved: {s}\n", .{ path, @errorName(err) });
    };
}

/// Write the card back over its `--sd-save` image when the run ends. A
/// failed write is reported and leaves the image file as it was.
pub fn saveBack(board: *const Board, io: std.Io, sd_path: ?[]const u8, save: bool) void {
    if (!save) return;
    const path = sd_path orelse return;
    disk_file.replace(io, std.Io.Dir.cwd(), path, &board.sd.img) catch |err| {
        std.debug.print("SD image {s}: not saved: {s}\n", .{ path, @errorName(err) });
    };
}

/// Size and format the card, or import a raw host image when requested.
pub fn prepare(
    board: *Board,
    io: std.Io,
    trace_sd: bool,
    sd_path: ?[]const u8,
    sd_size_mb: ?u32,
    sd_new: ?sd_format.Kind,
    sd_label: []const u8,
) !void {
    board.sd.trace = trace_sd;
    if (sd_path) |path| {
        if (sd_new != null or sd_size_mb != null) return error.ConflictingCardOptions;
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, std.heap.page_allocator, .unlimited) catch |err| {
            std.debug.print("cannot read SD image {s}: {s}\n", .{ path, @errorName(err) });
            return err;
        };
        defer std.heap.page_allocator.free(bytes);
        board.sd.img.loadBytes(bytes) catch |err| {
            std.debug.print("SD image {s}: {s}\n", .{ path, @errorName(err) });
            return err;
        };
        return;
    }
    if (sd_size_mb) |megabytes| {
        const blocks = megabytes *| (1024 * 1024 / sd_image.geometry.block_bytes);
        if (!board.sd.img.resize(blocks)) {
            std.debug.print("--sd-size {d}: not a card size this model can state exactly\n", .{megabytes});
            return error.BadCardSize;
        }
    }
    const kind = sd_new orelse return;
    board.sd_volume = sd_format.apply(&board.sd.img, kind, sd_label) catch |err| {
        std.debug.print("--sd-new {s}: {s}\n", .{ kind.text(), @errorName(err) });
        sd_advice.printRemedy(kind, err);
        return err;
    };
}
