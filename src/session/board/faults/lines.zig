//! The SPI and UART half of the session's fault hook (RA8EMU-520, slice 2).
//!
//! These lines carry one part per channel and have no acknowledge, so only
//! disconnected, stuck and garbage make sense on them; any other mode is
//! refused. The first set on a channel wraps its part in place; later sets
//! and clears only change that wrapper's mode, so nothing ever stacks. A
//! wrapper whose part was since swapped out is treated as gone.
const std = @import("std");
const fault_lines = @import("ra8_components").fault.lines;
const fault_spec = @import("ra8_components").fault.spec;

pub const Error = error{ NothingFitted, WrongMode } || std.mem.Allocator.Error;

/// The line wrapper's mode for a session fault; null clears it.
pub fn lineMode(mode: ?fault_spec.Mode) Error!fault_lines.LineMode {
    const wanted = mode orelse return .none;
    return switch (wanted) {
        .disconnected => .disconnected,
        .stuck => |value| .{ .stuck = value },
        .garbage => |seed| .{ .garbage = seed },
        else => Error.WrongMode,
    };
}

/// One wrapper slot per channel of a line whose parts are `Device`s.
pub fn Wrappers(comptime Wrapper: type, comptime Device: type, comptime count: usize) type {
    return struct {
        const Self = @This();
        held: [count]?*Wrapper = @splat(null),

        /// Put the part fitted in `slot` (channel `index`) into `mode`.
        pub fn set(
            self: *Self,
            arena: std.mem.Allocator,
            index: usize,
            slot: *?Device,
            mode: fault_lines.LineMode,
        ) Error!void {
            const fitted: *Device = if (slot.*) |*part| part else return Error.NothingFitted;
            if (self.held[index]) |wrapper| {
                if (fitted.context == @as(*anyopaque, wrapper)) return wrapper.set(mode);
            }
            if (mode == .none) return;
            const wrapper = try arena.create(Wrapper);
            wrapper.* = Wrapper.wrap(fitted.*);
            wrapper.set(mode);
            fitted.* = wrapper.device();
            self.held[index] = wrapper;
        }
    };
}
