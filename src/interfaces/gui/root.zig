//! gui_app: the GUI application's own files (RA8EMU-202, ADR 0001 and ADR
//! 0004 in the knowledge base, RA8EMU-A-8 and RA8EMU-A-2), as the module
//! that ra8_gui, the SDL backend and the tests import. It is given the
//! session, the adapters it talks and draws through, and the host, and
//! neither ra8_board nor ra8_chip (RA8EMU-984): the GUI reads and changes
//! the machine only through the Session API. main.zig and the sdl files
//! stay outside this module because they need SDL.
pub const geom = @import("geom.zig");
pub const render_driver = @import("render_driver.zig");
pub const platform = @import("platform.zig");
pub const headless = @import("headless.zig");
pub const camera = @import("camera/camera.zig");
pub const camera_view = @import("ui/camera_view.zig");
pub const session_link = @import("session_link.zig");
pub const status = @import("status/status.zig");
pub const status_strip = @import("ui/status_strip.zig");
pub const speed_field = @import("speed_field.zig");
pub const seek_field = @import("seek_field.zig");
pub const time = @import("time/time.zig");
pub const time_bar = @import("ui/time_bar.zig");
pub const history_strip = @import("ui/history_strip.zig");
pub const theme_picker = @import("ui/theme_picker.zig");
pub const colors = @import("ui/colors.zig");
pub const board_pane = @import("ui/board_pane.zig");
pub const board = @import("board/board.zig");
pub const fit = @import("ui/fit.zig");
pub const shell = @import("shell/shell.zig");
pub const local_session = @import("local_session.zig");
pub const local_native = @import("local_native.zig");
pub const local_native_link = @import("local_native_link.zig");
pub const session_worker = @import("session_worker.zig");
pub const preview_relay = @import("preview_relay.zig");
pub const wall_clock = @import("wall_clock.zig");
pub const console = @import("console/console.zig");
pub const console_strip = @import("ui/console_strip.zig");
pub const console_pane = @import("ui/console_pane.zig");
pub const registers_pane = @import("ui/registers_pane.zig");
pub const registers_capture = @import("registers_capture.zig");
pub const memory_pane = @import("ui/memory_pane.zig");
pub const map_layout = @import("map_layout.zig");
pub const map_pane = @import("ui/map_pane.zig");
pub const periph_pane = @import("ui/periph_pane.zig");
pub const periph_capture = @import("periph_capture.zig");
pub const memory_capture = @import("memory_capture.zig");
pub const disasm_pane = @import("ui/disasm_pane.zig");
pub const disasm_capture = @import("disasm_capture.zig");
pub const source_pane = @import("ui/source_pane.zig");
pub const source_capture = @import("source_capture.zig");
pub const stack_pane = @import("ui/stack_pane.zig");
pub const locals_pane = @import("ui/locals_pane.zig");
pub const flame = @import("flame/flame.zig");
pub const flame_pane = @import("ui/flame_pane.zig");
pub const hex_entry = @import("ui/hex_entry.zig");
pub const pane_edit = @import("pane_edit.zig");
pub const present_gate = @import("present_gate.zig");
pub const display_settings = @import("display_settings.zig");
pub const frame_pacer = @import("frame_pacer.zig");
pub const lcd_pacing = @import("lcd_pacing.zig");
pub const lcd_scrubber = @import("lcd_scrubber.zig");
pub const snapshot_ring = @import("snapshot_ring.zig");
pub const time_cursor = @import("time_cursor.zig");
pub const timeline_model = @import("timeline_model.zig");
pub const history_track = @import("history_track.zig");
pub const timeline_pane = @import("timeline_pane.zig");
pub const timeline_feed = @import("timeline_feed.zig");
pub const lcd_history = @import("lcd_history.zig");
pub const menu = @import("menu.zig");
pub const menu_bar = @import("menu_bar.zig");
pub const pane_layout = @import("ui/pane_layout.zig");
pub const window = @import("window/window.zig");
pub const script = @import("script/script.zig");
pub const video = @import("video/video.zig");
pub const fork_banner = @import("ui/fork_banner.zig");
pub const branch_list = @import("ui/branch_list.zig");
pub const filmstrip = @import("filmstrip.zig");
pub const branch_tree = @import("branch_tree.zig");
pub const diff_pane = @import("ui/diff_pane.zig");

pub const host_metrics_pane = @import("ui/host_metrics_pane.zig");
pub const device_metrics_pane = @import("ui/device_metrics_pane.zig");
