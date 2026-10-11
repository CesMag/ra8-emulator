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
pub const board = @import("board/board.zig");
pub const display = @import("display.zig");
pub const panel = @import("panel/panel.zig");
pub const boot_slots = @import("boot_slots.zig");
pub const breaks = @import("breaks/breaks.zig");
pub const breakpoint = @import("breakpoint.zig");
pub const call_decode = @import("call_decode.zig");
pub const commands = @import("commands.zig");
pub const core_view = @import("core_view.zig");
pub const disasm = @import("disasm.zig");
pub const duration = @import("duration.zig");
pub const dwarf = @import("dwarf/dwarf.zig");
pub const fault_file = @import("fault_file.zig");
pub const fpb = @import("fpb.zig");
pub const functions = @import("functions.zig");
pub const harness = @import("harness/harness.zig");
pub const cpu1 = @import("cpu1/cpu1.zig");
pub const hotspots = @import("hotspots.zig");
pub const itm_console = @import("itm_console.zig");
pub const mem_dump = @import("mem_dump.zig");
pub const pc_hits = @import("pc_hits.zig");
pub const place = @import("place/place.zig");
pub const profile = @import("profile.zig");
pub const region = @import("region/region.zig");
pub const periph_list = @import("periph_list.zig");
pub const registers = @import("registers.zig");
pub const rtos = @import("rtos/rtos.zig");
pub const run = @import("run/run.zig");
pub const txm = @import("txm/txm.zig");
pub const script = @import("script.zig");
pub const sections = @import("sections.zig");
pub const session = @import("session.zig");
pub const api = @import("api.zig");
pub const event = @import("event/event.zig");
pub const rtc = @import("rtc/rtc.zig");
pub const source = @import("source.zig");
pub const speed = @import("speed.zig");
pub const tap_part = @import("tap_part.zig");
pub const view = @import("view.zig");
pub const spacing = @import("spacing.zig");
pub const stack = @import("stack/stack.zig");
pub const state_options = @import("state_options.zig");
pub const step_hook = @import("step_hook.zig");
pub const stop_machine = @import("stop_machine.zig");
pub const symbols = @import("symbols.zig");
pub const taken_in = @import("taken_in.zig");
pub const tally = @import("tally.zig");
pub const touch_spec = @import("touch_spec.zig");
pub const unwind = @import("unwind/unwind.zig");
pub const watch = @import("watch/watch.zig");
pub const watchpoint = @import("watchpoint.zig");
pub const widget_tree = @import("widget_tree.zig");
pub const zig = @import("zig/zig.zig");
