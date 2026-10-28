//! cli_app: the command line application's own files (ADR 0004 in the
//! knowledge base, RA8EMU-A-2), as the module that ra8_emulator (main.zig)
//! and the tests import. It is given every library and nothing from the
//! GUI, and it never links SDL.
pub const cli = @import("cli.zig");
pub const eink_log = @import("eink_log.zig");
pub const probe_ctl = @import("probe_ctl.zig");
pub const serve = @import("serve/serve.zig");
pub const camera_source = @import("camera_source.zig");
pub const usb_disk_option = @import("usb_disk_option.zig");
pub const card = @import("card/card.zig");
pub const map_main = @import("map_main.zig");
pub const session_ctl = @import("session_ctl.zig");
pub const ctl = @import("ctl/ctl.zig");
pub const ctl_write = ctl.write;
pub const host = @import("host/host.zig");
pub const history_cli = @import("history_cli.zig");
pub const history_branch_cli = @import("history_branch_cli.zig");
pub const history_maint_cli = @import("history_maint_cli.zig");
pub const history_replay_elf_cli = @import("history_replay_elf_cli.zig");
pub const video_out = @import("video_out.zig");
pub const gif_out = @import("gif_out.zig");
pub const debug_front = @import("debug_front.zig");
pub const zig = @import("zig/zig.zig");
pub const sweep = @import("sweep/sweep.zig");
pub const image_file = @import("image_file.zig");
pub const parts = @import("parts.zig");
pub const report = @import("report.zig");
