//! The backtrace request (RA8EMU-1125): a core's call chain walked with the
//! .debug_frame of the image it last loaded, the way `backtrace` walks it
//! (session/report.zig), each frame named from the symbol table and placed
//! from the line table. Without CFI for the stop the chain is the pc and,
//! when it holds a code address, lr; without an image the frames carry
//! only their pcs.
const std = @import("std");
const rpc = @import("ra8_rpc_wire");
const proto = @import("session_rpc.zig");
const handlers = @import("session_handlers.zig");
const backtrace_wire = @import("backtrace_wire.zig");
const api = @import("ra8_session").api;
const symbols = @import("ra8_session").symbols;
const dwarf_line = @import("ra8_session").dwarf_line;
const unwind = @import("ra8_session").unwind;
const txm_debug = @import("ra8_session").txm_debug;

const Image = symbols.Image;
const Outcome = rpc.Outcome(proto.Backtrace);

comptime {
    std.debug.assert(proto.backtrace_frames == unwind.limits.frames);
}

pub fn backtrace(context: *handlers.Context, args: proto.CoreOnly) Outcome {
    const which: api.Core = @fromBackingInt(@intCast(@backingInt(args.core)));
    const view = context.session.view(which) catch |err| return refuse(err);
    if (context.scratch.len < proto.backtrace_bytes) return refuse(error.NoRoom);
    const image = imageOf(context, which);
    var walked: [unwind.limits.frames]unwind.Frame = undefined;
    const count = walk(view, image, &walked) catch |err| return refuse(err);
    var at: usize = 0;
    for (walked[0..count], 0..) |found, index| {
        const frame = describe(image, context.modules, found, index);
        backtrace_wire.put(context.scratch[0..proto.backtrace_bytes], &at, frame) catch |err| return refuse(err);
    }
    return .{ .ok = .{ .core = args.core, .count = @intCast(count), .frames = context.scratch[0..at] } };
}

fn walk(view: anytype, image: ?Image, into: *[unwind.limits.frames]unwind.Frame) !usize {
    const cfi = if (image) |found| dwarf_line.section(found, ".debug_frame") else &.{};
    var count = unwind.walk(cfi, try unwind.registersOf(view), try view.register(.psp), view, into);
    const lr = try view.register(.lr);
    if (count < 2 and count < into.len and lr != 0 and lr < unwind.limits.exc_return) {
        into[count] = .{ .pc = lr & ~@as(u32, 1) };
        count += 1;
    }
    return count;
}

/// Frame `index` of the walk. A return address is the instruction after
/// the call, so a caller's frame is named and placed from the byte before.
fn describe(image: ?Image, modules: ?*const txm_debug.Table, found: unwind.Frame, index: usize) proto.StackFrame {
    var frame: proto.StackFrame = .{ .pc = found.pc, .interrupted = @intFromBool(index > 0 and found.exact), .offset = 0, .line = 0, .name = "", .file = "" };
    const at = if (index == 0 or found.exact) found.pc else found.pc -% 1;
    if (modules) |table| if (table.inside(at)) |named| return withName(frame, named, found.pc -% at);
    const loaded = image orelse return frame;
    if (symbols.inside(loaded, at)) |named| frame = withName(frame, named, found.pc -% at);
    const placed = (dwarf_line.lookup(dwarf_line.ofImage(loaded), at) catch null) orelse return frame;
    const base = std.fs.path.basename(placed.file.name);
    frame.file = base[0..@min(base.len, proto.frame_file_cap)];
    frame.line = placed.line;
    return frame;
}

/// `frame` named for the function `named`; `back` is how far the frame's
/// pc is past the address that was looked up.
fn withName(frame: proto.StackFrame, named: symbols.Inside, back: u32) proto.StackFrame {
    var out = frame;
    out.name = named.name[0..@min(named.name.len, proto.frame_name_cap)];
    out.offset = named.offset +% back;
    return out;
}

/// The image the serving side holds for `core`, if any.
fn imageOf(context: *handlers.Context, core: api.Core) ?Image {
    const mapping = context.mapping orelse return null;
    const imageFn = mapping.imageFn orelse return null;
    return imageFn(mapping.context, @backingInt(core));
}

fn refuse(err: anyerror) Outcome {
    if (err == error.CoreNotAttached) return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.no_core)) };
    return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.refused)) };
}
