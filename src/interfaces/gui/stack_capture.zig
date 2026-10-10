//! Fills the call stack pane's snapshot from the session (RA8EMU-1079),
//! walking the image's .debug_frame the way `backtrace` does
//! (session_report.zig). ui/stack_pane.zig draws the result without
//! importing the session.
const std = @import("std");
const elf = @import("../../board/image/elf.zig");
const dwarf_line = @import("../../session/dwarf_line.zig");
const session_api = @import("../../session/session_api.zig");
const symbols = @import("../../session/symbols.zig");
const unwind = @import("../../session/unwind.zig");
const stack_pane = @import("ui/stack_pane.zig");

comptime {
    std.debug.assert(stack_pane.max_frames == unwind.limits.frames);
}

/// Walks `core`'s call chain. Without CFI for the stop the chain is pc and,
/// when it holds a code address, lr, as `backtrace` falls back to. With no
/// image the frames carry only their pcs.
pub fn capture(session: *session_api.Session, core: session_api.Core, image: ?elf.Image) anyerror!stack_pane.Snapshot {
    const view = try session.view(core);
    var walked: [stack_pane.max_frames]unwind.Frame = undefined;
    const cfi = if (image) |found| dwarf_line.section(found, ".debug_frame") else &.{};
    var count = unwind.walk(cfi, try unwind.registersOf(view), try view.register(.psp), view, &walked);
    const lr = try view.register(.lr);
    if (count < 2 and lr != 0 and lr < unwind.limits.exc_return) {
        walked[count] = .{ .pc = lr & ~@as(u32, 1) };
        count += 1;
    }
    var snapshot: stack_pane.Snapshot = .{ .count = count };
    const lines = if (image) |found| dwarf_line.ofImage(found) else dwarf_line.Sections{};
    for (walked[0..count], snapshot.frames[0..count], 0..) |found, *frame, index| {
        frame.* = .{ .pc = found.pc, .interrupted = index > 0 and found.exact };
        // A return address is the instruction after the call; name the call.
        const at = if (index == 0 or found.exact) found.pc else found.pc -% 1;
        if (image) |loaded| nameFrame(frame, loaded, at);
        placeFrame(frame, lines, at);
    }
    return snapshot;
}

fn nameFrame(frame: *stack_pane.Frame, image: elf.Image, at: u32) void {
    const found = symbols.inside(image, at) orelse return;
    frame.name_len = @min(found.name.len, stack_pane.name_cap);
    @memcpy(frame.name_buf[0..frame.name_len], found.name[0..frame.name_len]);
    frame.offset = found.offset +% (frame.pc -% at);
}

fn placeFrame(frame: *stack_pane.Frame, lines: dwarf_line.Sections, at: u32) void {
    const found = (dwarf_line.lookup(lines, at) catch null) orelse return;
    const base = std.fs.path.basename(found.file.name);
    frame.file_len = @min(base.len, stack_pane.file_cap);
    @memcpy(frame.file_buf[0..frame.file_len], base[0..frame.file_len]);
    frame.line = found.line;
}
