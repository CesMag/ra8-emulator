//! The webcam's "Always for this project", kept between runs (RA8EMU-500,
//! RA8EMU-1124). The project is the directory the application was started
//! in, and the answer is one marker file there. Only that exact marker is
//! consent: a project with no marker, one that cannot be read, an empty
//! file or any other contents asks again, which never opens the webcam
//! unasked. `withdraw` takes the answer back by removing the marker, and so
//! does deleting the file by hand.
const std = @import("std");

/// The marker, relative to the project directory.
pub const dir_name = ".ra8-emulator";
pub const file_name = "webcam-always";
pub const path = dir_name ++ "/" ++ file_name;

/// What the marker holds, so a stray empty file is not read as consent.
pub const contents = "always\n";

/// Whether this project answered Always in an earlier run.
pub fn load(io: std.Io, project: std.Io.Dir) bool {
    // One byte spare, so a longer marker reads past `contents` and fails.
    var buf: [contents.len + 1]u8 = undefined;
    const read = project.readFile(io, path, &buf) catch return false;
    return std.mem.eql(u8, read, contents);
}

/// Records Always for this project.
pub fn save(io: std.Io, project: std.Io.Dir) !void {
    try project.createDirPath(io, dir_name);
    try project.writeFile(io, .{ .sub_path = path, .data = contents });
}

/// Takes Always back for this project. A project with no marker has
/// nothing to take back, which is not an error; a marker that will not go
/// is, because the next run would still find it.
pub fn withdraw(io: std.Io, project: std.Io.Dir) !void {
    project.deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    // The directory goes with its last file; one holding anything else stays.
    project.deleteDir(io, dir_name) catch {};
}
