//! cli_app: the command line application's own files (ADR 0004 in the
//! knowledge base, RA8EMU-A-2), as the module that ra8_emulator (main.zig)
//! and the tests import. It is given every library and nothing from the
//! GUI, and it never links SDL.
pub const cli = @import("cli.zig");
pub const eink_log = @import("eink_log.zig");
pub const probe_ctl = @import("probe_ctl.zig");
pub const serve_main = @import("serve_main.zig");
pub const camera_source = @import("camera_source.zig");
pub const usb_disk_option = @import("usb_disk_option.zig");
pub const card_apps = @import("card_apps.zig");
pub const map_main = @import("map_main.zig");
pub const serve_listen = @import("serve_listen.zig");
pub const session_ctl = @import("session_ctl.zig");
pub const host_spawn = @import("host_spawn.zig");
pub const video_out = @import("video_out.zig");
pub const gif_out = @import("gif_out.zig");
pub const debug_front = @import("debug_front.zig");
pub const zig_debug_front = @import("zig_debug_front.zig");
pub const sweep_cli = @import("sweep_cli.zig");
pub const sweep_elf = @import("sweep_elf.zig");
pub const image_file = @import("image_file.zig");
pub const parts = @import("parts.zig");
pub const zig_run = @import("zig_run.zig");
pub const report = @import("report.zig");
