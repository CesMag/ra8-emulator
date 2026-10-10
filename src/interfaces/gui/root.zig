//! gui_app: the GUI application's own files (RA8EMU-202, ADR 0001 and ADR
//! 0004 in the knowledge base, RA8EMU-A-8 and RA8EMU-A-2), as the module
//! that ra8_gui, the SDL backend and the tests import. It is given the
//! session, the adapters it talks and draws through, and the host, and
//! neither ra8_board nor ra8_chip (RA8EMU-984): the GUI reads and changes
//! the machine only through the Session API. main.zig, gui_window.zig and
//! the sdl files stay outside this module because they need SDL.
pub const platform = @import("platform.zig");
pub const headless = @import("headless.zig");
pub const camera_panel = @import("camera_panel.zig");
pub const camera_open = @import("camera_open.zig");
pub const camera_view = @import("ui/camera_view.zig");
pub const session_link = @import("session_link.zig");
pub const status_bar = @import("status_bar.zig");
pub const status_strip = @import("ui/status_strip.zig");
pub const status_capture = @import("status_capture.zig");
pub const speed_field = @import("speed_field.zig");
pub const time_readout = @import("time_readout.zig");
pub const time_bar = @import("ui/time_bar.zig");
pub const time_bar_capture = @import("time_bar_capture.zig");
pub const colors = @import("ui/colors.zig");
pub const board_pane = @import("ui/board_pane.zig");
pub const board_capture = @import("board_capture.zig");
pub const fit = @import("ui/fit.zig");
pub const board_input = @import("board_input.zig");
pub const board_touch = @import("board_touch.zig");
pub const shell_frame = @import("ui/shell_frame.zig");
pub const shell_main = @import("shell_main.zig");
pub const shell_startup = @import("shell_startup.zig");
pub const local_session = @import("local_session.zig");
pub const shell_loop = @import("shell_loop.zig");
pub const shell_panes = @import("shell_panes.zig");
pub const shell_console = @import("shell_console.zig");
pub const shell_board = @import("shell_board.zig");
pub const shell_devices = @import("shell_devices.zig");
pub const shell_fault = @import("shell_fault.zig");
pub const shell_field = @import("ui/shell_field.zig");
pub const shell_plug = @import("shell_plug.zig");
pub const shell_registers = @import("shell_registers.zig");
pub const shell_memory = @import("shell_memory.zig");
pub const shell_camera = @import("shell_camera.zig");
pub const shell_camera_file = @import("shell_camera_file.zig");
pub const shell_titles = @import("shell_titles.zig");
pub const console_log = @import("console_log.zig");
pub const console_pane = @import("ui/console_pane.zig");
pub const registers_pane = @import("ui/registers_pane.zig");
pub const registers_capture = @import("registers_capture.zig");
pub const memory_pane = @import("ui/memory_pane.zig");
pub const memory_capture = @import("memory_capture.zig");
pub const disasm_pane = @import("ui/disasm_pane.zig");
pub const disasm_capture = @import("disasm_capture.zig");
pub const source_pane = @import("ui/source_pane.zig");
pub const source_capture = @import("source_capture.zig");
pub const stack_pane = @import("ui/stack_pane.zig");
pub const stack_capture = @import("stack_capture.zig");
pub const hex_entry = @import("ui/hex_entry.zig");
pub const pane_edit = @import("pane_edit.zig");
pub const present_gate = @import("present_gate.zig");
pub const pane_layout = @import("ui/pane_layout.zig");
pub const window_still = @import("window_still.zig");
pub const window_stills = @import("window_stills.zig");
