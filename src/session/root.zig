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
pub const board_boundary = @import("board/boundary.zig");
pub const board_display = @import("board/display.zig");
pub const display = @import("display.zig");
pub const panel_watch = @import("panel/watch.zig");
pub const panel_diff = @import("panel/diff.zig");
pub const board_events = @import("board/events.zig");
pub const board_faults = @import("board/faults/faults.zig");
pub const board_leds = @import("board/leds.zig");
pub const board_plug = @import("board/plug.zig");
pub const board_rtc = @import("board/rtc.zig");
pub const board_schedule = @import("board/schedule.zig");
pub const board_speed = @import("board/speed.zig");
pub const board_state = @import("board/state.zig");
pub const boot_slots = @import("boot_slots.zig");
pub const break_list = @import("break/list.zig");
pub const break_table = @import("break/table.zig");
pub const breakpoint = @import("breakpoint.zig");
pub const call_decode = @import("call_decode.zig");
pub const commands = @import("commands.zig");
pub const core_view = @import("core_view.zig");
pub const disasm = @import("disasm.zig");
pub const duration = @import("duration.zig");
pub const dwarf_cursor = @import("dwarf/cursor.zig");
pub const dwarf_frame = @import("dwarf/frame.zig");
pub const dwarf_info = @import("dwarf/info.zig");
pub const dwarf_line = @import("dwarf/line/line.zig");
pub const dwarf_line_find = @import("dwarf/line/find.zig");
pub const fault_file = @import("fault_file.zig");
pub const fpb = @import("fpb.zig");
pub const functions = @import("functions.zig");
pub const harness = @import("harness/harness.zig");
pub const hotspots = @import("hotspots.zig");
pub const itm_console = @import("itm_console.zig");
pub const mem_dump = @import("mem_dump.zig");
pub const pc_hits = @import("pc_hits.zig");
pub const place = @import("place/place.zig");
pub const profile = @import("profile.zig");
pub const region_map = @import("region/map/map.zig");
pub const region_map_json = @import("region/map/json.zig");
pub const region_map_text = @import("region/map/text.zig");
pub const registers = @import("registers.zig");
pub const rtc_start = @import("rtc/start.zig");
pub const rtos_hook = @import("rtos/hook.zig");
pub const rtos_load = @import("rtos/load.zig");
pub const rtos_names = @import("rtos/names.zig");
pub const rtos_report = @import("rtos/report.zig");
pub const run_loop = @import("run/loop.zig");
pub const script = @import("script.zig");
pub const sections = @import("sections.zig");
pub const session = @import("session.zig");
pub const api = @import("api.zig");
pub const event_stream = @import("event/stream.zig");
pub const rtc = @import("rtc/rtc.zig");
pub const source = @import("source.zig");
pub const speed = @import("speed.zig");
pub const tap_part = @import("tap_part.zig");
pub const view = @import("view.zig");
pub const spacing = @import("spacing.zig");
pub const stack_low = @import("stack/low.zig");
pub const stack_profile = @import("stack/profile.zig");
pub const stack_samples = @import("stack/samples.zig");
pub const state_options = @import("state_options.zig");
pub const step_hook = @import("step_hook.zig");
pub const stop_machine = @import("stop_machine.zig");
pub const symbols = @import("symbols.zig");
pub const taken_in = @import("taken_in.zig");
pub const tally = @import("tally.zig");
pub const touch_spec = @import("touch_spec.zig");
pub const unwind = @import("unwind/unwind.zig");
pub const watch_bus = @import("watch/bus.zig");
pub const watch_table = @import("watch/table.zig");
pub const watchpoint = @import("watchpoint.zig");
pub const widget_tree = @import("widget_tree.zig");
pub const zig_break = @import("zig/break.zig");
pub const zig_drive = @import("zig/drive.zig");
pub const zig_script = @import("zig/script.zig");
pub const zig_snapshot = @import("zig/snapshot.zig");
pub const zig_stop = @import("zig/stop.zig");
pub const zig_undefined = @import("zig/undefined.zig");
pub const zig_watch = @import("zig/watch.zig");
pub const board_camera = @import("board/camera.zig");
