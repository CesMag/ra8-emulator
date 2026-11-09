//! Action definitions for GUI automation scripting (RA8EMU-1120).
//! Defines the parsed actions, timing specifications, and named UI targets.
const std = @import("std");

pub const TimeSpec = union(enum) {
    time_ns: u64,
    frame: u32,
    virtual_ns: u64,
    wall_ns: u64,

    pub fn matches(self: TimeSpec, elapsed_ns: u64, frame_idx: u32) bool {
        return self.matchesWithVirtual(elapsed_ns, 0, frame_idx);
    }

    pub fn matchesWithVirtual(self: TimeSpec, wall_ns: u64, virtual_ns: u64, frame_idx: u32) bool {
        return switch (self) {
            .time_ns, .wall_ns => |ns| wall_ns >= ns,
            .virtual_ns => |ns| virtual_ns >= ns,
            .frame => |f| frame_idx >= f,
        };
    }
};

pub const NamedTarget = enum {
    bar_run,
    bar_pause,
    bar_step,
    bar_step_over,
    bar_step_out,
    bar_speed,
    bar_seek,
    bar_track,
    camera_allow_once,
    camera_always,
    camera_cam,
    camera_grd,
    board_sw1,
    board_sw2,
    banner_confirm,
    banner_cancel,
    tree_node_0,
    tree_node_1,
    tree_node_2,
    diff_earlier,
    diff_later,
};

pub const Target = union(enum) {
    coord: struct { x: i32, y: i32 },
    named: NamedTarget,
    touch: struct { x: u16, y: u16 },
};

pub const Drag = struct {
    from_x: i32,
    from_y: i32,
    to_x: i32,
    to_y: i32,
    duration_ms: u32,
};

/// Key codes a script's `key` action names (platform.Event.key's `code`).
/// The window's extended keys use SDL scancode numbering, the same table
/// time/bar_capture.zig's key_f5/key_f10/key_f11/key_home/key_end come
/// from; the arrows follow the same numbering.
pub const KeyCode = struct {
    pub const f5: u32 = 0x4000003E;
    pub const f10: u32 = 0x40000043;
    pub const f11: u32 = 0x40000044;
    pub const home: u32 = 0x4000004A;
    pub const end: u32 = 0x4000004D;
    pub const right: u32 = 0x4000004F;
    pub const left: u32 = 0x40000050;
};

pub const Action = union(enum) {
    click: Target,
    drag: Drag,
    type_text: []const u8,
    key: struct {
        code: u32,
        /// The shift modifier was held with the key.
        shift: bool = false,
        /// The OS's shortcut modifier was held (platform.Event.key's `primary`).
        primary: bool = false,
    },
    quit,
};

pub const Item = struct {
    at: TimeSpec,
    action: Action,
    executed: bool = false,
};
