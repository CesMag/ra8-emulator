//! The webcam consent gate (RA8EMU-506): the host camera is opened only
//! when the user picked `--camera-source webcam[:DEVICE]` and then either
//! answered y on the terminal or passed `--allow-webcam` for an unattended
//! run. Anything else, including an empty answer or a closed terminal,
//! refuses, and nothing is opened. Capture start and stop are logged.
const std = @import("std");

/// How the run may answer the consent question.
pub const Grant = enum {
    /// Ask on the terminal (the default).
    ask,
    /// `--allow-webcam`: consent given up front for an unattended run.
    allowed,
};

pub const Decision = enum { granted, refused };

/// The device a webcam source opens when no DEVICE is named.
pub const default_device = "/dev/video0";

pub const DeviceError = error{BadDevice};

/// `webcam` opens /dev/video0, `webcam:N` opens /dev/videoN and
/// `webcam:/path` opens that path. The name lands in `buf` when built.
pub fn device(buf: []u8, arg: []const u8) DeviceError![]const u8 {
    if (arg.len == 0) return default_device;
    if (arg[0] == '/') return arg;
    _ = std.fmt.parseUnsigned(u8, arg, 10) catch return error.BadDevice;
    return std.fmt.bufPrint(buf, "/dev/video{s}", .{arg}) catch error.BadDevice;
}

/// True for an answer of y or yes, in any case, around blanks.
pub fn isYes(line: []const u8) bool {
    const word = std.mem.trim(u8, line, " \t\r\n");
    return std.ascii.eqlIgnoreCase(word, "y") or std.ascii.eqlIgnoreCase(word, "yes");
}

/// Decides whether `dev` may be opened. With `.ask`, writes the question
/// to `writer` and reads one answer line from `reader`; the end of input or
/// a read error refuses.
pub fn decide(grant: Grant, dev: []const u8, reader: *std.Io.Reader, writer: *std.Io.Writer) Decision {
    if (grant == .allowed) return .granted;
    writer.print("--camera-source webcam: open the host camera {s}? [y/N] ", .{dev}) catch return .refused;
    writer.flush() catch return .refused;
    const line = reader.takeDelimiter('\n') catch return .refused;
    return if (isYes(line orelse return .refused)) .granted else .refused;
}

/// The log line for a capture that starts on `dev`.
pub fn logStart(writer: *std.Io.Writer, dev: []const u8) !void {
    try writer.print("camera: webcam capture started on {s}\n", .{dev});
}

/// The log line for a capture that stops, releasing `dev`.
pub fn logStop(writer: *std.Io.Writer, dev: []const u8) !void {
    try writer.print("camera: webcam capture stopped, {s} released\n", .{dev});
}

/// logStop to stderr, for a capture's close, which has no io: the same
/// stderr path std.debug.print takes.
pub fn logStopStderr(dev: []const u8) void {
    const locked = std.debug.lockStderr(&.{});
    defer std.debug.unlockStderr();
    logStop(&locked.file_writer.interface, dev) catch {};
}
