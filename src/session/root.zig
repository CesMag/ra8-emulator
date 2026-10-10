//! ra8_session: the one embedding API (ADR 0004 sections 2 and 3, knowledge
//! base article RA8EMU-A-2). `harness.open` gives the owner and its
//! Session: run, pause and step per core, registers and memory, breaks and
//! watches, input and plug, snapshot save and load, and events. Behind it
//! are the debugger internals (the stop machine, DWARF, unwinding, symbols,
//! the command language), the run loop that drives both cores, and the run
//! instrumentation the reports read.
//!
//! It imports the board, the chip and the components, whose plug, fault
//! and input types the Session API speaks. It never imports the host: a
//! file it reads comes through the `std.Io` its caller hands in.
pub const board_boundary = @import("board_boundary.zig");
pub const board_display = @import("board_display.zig");
pub const board_events = @import("board_events.zig");
pub const board_faults = @import("board_faults.zig");
pub const board_leds = @import("board_leds.zig");
pub const board_plug = @import("board_plug.zig");
pub const board_rtc = @import("board_rtc.zig");
pub const board_schedule = @import("board_schedule.zig");
pub const board_speed = @import("board_speed.zig");
pub const board_state = @import("board_state.zig");
pub const boot_slots = @import("boot_slots.zig");
pub const break_list = @import("break_list.zig");
pub const break_table = @import("break_table.zig");
pub const breakpoint = @import("breakpoint.zig");
pub const call_decode = @import("call_decode.zig");
pub const commands = @import("commands.zig");
pub const core_view = @import("core_view.zig");
pub const disasm = @import("disasm.zig");
pub const duration = @import("duration.zig");
pub const dwarf_cursor = @import("dwarf_cursor.zig");
pub const dwarf_frame = @import("dwarf_frame.zig");
pub const dwarf_info = @import("dwarf_info.zig");
pub const dwarf_line = @import("dwarf_line.zig");
pub const dwarf_line_find = @import("dwarf_line_find.zig");
pub const fault_file = @import("fault_file.zig");
pub const fpb = @import("fpb.zig");
pub const functions = @import("functions.zig");
pub const harness = @import("harness.zig");
pub const hotspots = @import("hotspots.zig");
pub const itm_console = @import("itm_console.zig");
pub const mem_dump = @import("mem_dump.zig");
pub const pc_hits = @import("pc_hits.zig");
pub const place = @import("place.zig");
pub const profile = @import("profile.zig");
pub const region_map = @import("region_map.zig");
pub const region_map_json = @import("region_map_json.zig");
pub const region_map_text = @import("region_map_text.zig");
pub const registers = @import("registers.zig");
pub const rtc_start = @import("rtc_start.zig");
pub const rtos_hook = @import("rtos_hook.zig");
pub const rtos_load = @import("rtos_load.zig");
pub const rtos_names = @import("rtos_names.zig");
pub const rtos_report = @import("rtos_report.zig");
pub const run_loop = @import("run_loop.zig");
pub const script = @import("script.zig");
pub const sections = @import("sections.zig");
pub const session = @import("session.zig");
pub const session_api = @import("session_api.zig");
pub const session_event_stream = @import("session_event_stream.zig");
pub const session_rtc = @import("session_rtc.zig");
pub const session_source = @import("session_source.zig");
pub const session_speed = @import("session_speed.zig");
pub const session_tap_part = @import("session_tap_part.zig");
pub const session_view = @import("session_view.zig");
pub const spacing = @import("spacing.zig");
pub const stack_low = @import("stack_low.zig");
pub const stack_profile = @import("stack_profile.zig");
pub const stack_samples = @import("stack_samples.zig");
pub const state_options = @import("state_options.zig");
pub const step_hook = @import("step_hook.zig");
pub const stop_machine = @import("stop_machine.zig");
pub const symbols = @import("symbols.zig");
pub const taken_in = @import("taken_in.zig");
pub const tally = @import("tally.zig");
pub const touch_spec = @import("touch_spec.zig");
pub const unwind = @import("unwind.zig");
pub const watch_bus = @import("watch_bus.zig");
pub const watch_table = @import("watch_table.zig");
pub const watchpoint = @import("watchpoint.zig");
pub const widget_tree = @import("widget_tree.zig");
pub const zig_break = @import("zig_break.zig");
pub const zig_drive = @import("zig_drive.zig");
pub const zig_script = @import("zig_script.zig");
pub const zig_snapshot = @import("zig_snapshot.zig");
pub const zig_stop = @import("zig_stop.zig");
pub const zig_undefined = @import("zig_undefined.zig");
pub const zig_watch = @import("zig_watch.zig");
