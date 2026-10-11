//! ra8_emulator: the RA8D2 board emulator's command line (#14, the Zig
//! rewrite; moved here from src/main.zig by RA8EMU-1087, ADR 0004 step 6).
//! It never links SDL and imports nothing from the GUI: the window and its
//! debugger shell are ra8_gui (src/interfaces/gui/main.zig).
//!
//! This file opens the ELF and hands the run to the Zig core
//! (src/interfaces/cli/zig/main.zig). A debugger command line goes to the
//! debug front instead. Everything it calls is the cli_app module (root.zig),
//! which reaches the machine through the library modules.
const std = @import("std");
const app = @import("cli_app");
const host = @import("ra8_host");

// A macOS build carries the Info.plist the camera permission needs.
comptime {
    _ = host.camera.av_info_plist;
}

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(allocator);
    if (argv.len >= 3 and std.mem.eql(u8, argv[1], "ctl") and std.mem.eql(u8, argv[2], "probe")) return app.probe_ctl.run(allocator, io, argv);
    if (argv.len >= 3 and std.mem.eql(u8, argv[1], "ctl") and (std.mem.eql(u8, argv[2], "--connect") or std.mem.eql(u8, argv[2], "--host"))) return app.session_ctl.run(allocator, io, init.environ_map, argv);
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "--map")) return app.map_main.run(allocator, io, argv);
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "serve")) return app.serve.main.run(allocator, io, argv);
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "sweep")) return app.sweep.cli.run(io, init.environ_map, argv);
    const options = app.cli.parse(argv) catch return app.debug_front.refused(allocator, io, argv);
    const image = app.image_file.open(io, allocator, options.path) catch return 1;
    return app.zig.run.main_path.run(allocator, io, image, options);
}
