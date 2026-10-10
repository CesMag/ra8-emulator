//! The --usb-disk option: a blank volume, or a raw image read from the
//! host, plugged into the board's USB stick (RA8EMU-1020: the host read
//! lives here, not in the board).
const std = @import("std");
const usb = @import("ra8_board").usb;
const usb_plug = @import("ra8_board").usb_plug;
const disk_file = @import("ra8_host").disk_file;

/// The disk bytes a spec names, owned by `allocator`.
pub fn load(allocator: std.mem.Allocator, io: std.Io, spec: []const u8) ![]u8 {
    if (std.mem.eql(u8, spec, usb_plug.blank_spec)) return usb_plug.blank(allocator);
    const disk = try disk_file.read(allocator, io, spec, usb_plug.max_image);
    errdefer allocator.free(disk);
    try usb_plug.check(disk);
    return disk;
}

/// What the option asked for, if anything: load it and plug it in, or say
/// on stderr why not.
pub fn apply(board_usb: *usb.Usb, allocator: std.mem.Allocator, io: std.Io, spec: ?[]const u8) !void {
    const named = spec orelse return;
    const disk = load(allocator, io, named) catch |err| {
        std.debug.print("--usb-disk {s}: {s}\n", .{ named, @errorName(err) });
        return err;
    };
    usb_plug.plug(board_usb, disk);
}
