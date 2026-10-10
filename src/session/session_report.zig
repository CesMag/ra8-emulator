//! How a stop is placed in the program: an address with its symbol, the
//! instruction there, and the call chain above it (RA8EMU-114).
//!
//! These read the core only through core_view, so any session prints the
//! same lines for
//! the same stop.
const elf = @import("../board/image/elf.zig");
const core_view = @import("core_view.zig");
const dwarf_line = @import("dwarf_line.zig");
const session_source = @import("session_source.zig");
const session_view = @import("session_view.zig");
const symbols = @import("symbols.zig");
const unwind = @import("unwind.zig");
const stop_machine = @import("stop_machine.zig");

/// An address as eight hex digits, with `<symbol+offset>` when the image
/// has a function covering it.
pub fn where(image: ?elf.Image, address: u32, out: anytype) !void {
    try out.print("0x{X:0>8}", .{address});
    const found = symbols.inside(image orelse return, address) orelse return;
    if (found.offset == 0) return out.print(" <{s}>", .{found.name});
    try out.print(" <{s}+{d}>", .{ found.name, found.offset });
}

/// An address, its symbol, and the instruction there.
pub fn line(view: core_view.View, image: ?elf.Image, address: u32, out: anytype) !void {
    try where(image, address, out);
    try out.print(": ", .{});
    _ = try session_view.instruction(out, view, address);
    try out.print("\n", .{});
}

/// The call chain, walked with the image's .debug_frame, each frame with
/// its source line when the image has one. Without CFI for the stop it is
/// the pc and lr.
pub fn backtrace(view: core_view.View, image: ?elf.Image, out: anytype) !void {
    var frames: [unwind.limits.frames]unwind.Frame = undefined;
    const frame = if (image) |found| dwarf_line.section(found, ".debug_frame") else &.{};
    const psp = try view.register(.psp);
    var count = unwind.walk(frame, try unwind.registersOf(view), psp, view, &frames);
    if (count < 2) {
        frames[1] = .{ .pc = try view.register(.lr) & ~@as(u32, 1) };
        count = 2;
    }
    const sections = session_source.of(image);
    var number: usize = 0;
    for (frames[0..count], 0..) |found, index| {
        // An exception sits between a handler and what it interrupted;
        // gdb shows it as a frame of its own, so the numbers match.
        if (index > 0 and found.exact) {
            try out.print("#{d} <signal handler called>\n", .{number});
            number += 1;
        }
        try out.print("#{d} ", .{number});
        number += 1;
        try where(image, found.pc, out);
        try session_source.at(out, sections, if (found.exact) found.pc else found.pc -% 1);
        try out.print("\n", .{});
    }
}

/// What a stop says before its line: nothing for a step, the break, watch
/// or unit that stopped the core, or a halt. `temporary` names a break
/// that was a `tbreak`.
pub fn prefix(out: anytype, stop: stop_machine.Stop, temporary: bool) !void {
    switch (stop) {
        .stepped => {},
        .breakpoint => |id| try out.print("{s} {d}, ", .{ if (temporary) "Temporary breakpoint" else "Breakpoint", id }),
        .watchpoint => |hit| try out.print("Watchpoint {d}: {s} of {d} at 0x{X:0>8}, ", .{
            hit.id, @tagName(hit.access), hit.width, hit.address,
        }),
        .halt_requested => try out.print("Halted, ", .{}),
        .unit_break => |index| try out.print("Hardware breakpoint FP_COMP{d}, ", .{index}),
        .unit_watch => |index| try out.print("Hardware watchpoint DWT_COMP{d}, ", .{index}),
    }
}
