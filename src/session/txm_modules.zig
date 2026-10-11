//! The ThreadX Module Manager's loaded modules, read from target memory
//! (RA8EMU-1139, under RA8EMU-1084).
//!
//! The manager keeps every loaded module on a circular, doubly linked list
//! headed by `_txm_module_manager_loaded_list_ptr`. Each entry is a
//! TXM_MODULE_INSTANCE from common_modules/inc/txm_module.h at the ThreadX
//! revision the firmware pins. Its first fields are plain words, so their
//! offsets hold on any 32-bit port. The list link sits after the port's MPU
//! extension, two TX_THREADs and a TX_QUEUE, so its offset is the firmware's
//! build: the M85 manager (ports_module/cortex_m33/gnu, with RA8FW-484's
//! txm_module_port.h at 7 MPU entries, 4 shared) and the kernel config in
//! port/threadx/inc/tx_user.h. Measured there with offsetof: the instance is
//! 1180 bytes, TX_THREAD 232, and loaded_next sits at 1172.
//!
//! This file only knows the layout. Whatever reads target memory is passed
//! in as `memory`, anything with `read(address: u32, into: []u8) bool`.
const std = @import("std");

/// The symbol whose word points at the first loaded module.
pub const list_symbol = "_txm_module_manager_loaded_list_ptr";

/// TXM_MODULE_ID, "MODU": every live instance starts with it.
pub const instance_id: u32 = 0x4D4F4455;

/// Where each field sits in a TXM_MODULE_INSTANCE.
pub const offset = struct {
    pub const id: u32 = 0;
    pub const name: u32 = 4;
    pub const state: u32 = 8;
    pub const code_start: u32 = 24;
    pub const code_size: u32 = 32;
    pub const data_start: u32 = 44;
    pub const data_size: u32 = 56;
    pub const loaded_next: u32 = 1172;
};

/// TXM_MODULE_LOADED through TXM_MODULE_UNLOADED, and anything else.
pub const State = enum(u32) {
    loaded = 1,
    started = 2,
    stopping = 3,
    stopped = 4,
    unloaded = 5,
    _,

    /// The word the report prints, or "unknown" for a value off the list.
    pub fn text(state: State) []const u8 {
        return switch (state) {
            .loaded => "loaded",
            .started => "started",
            .stopping => "stopping",
            .stopped => "stopped",
            .unloaded => "unloaded",
            _ => "unknown",
        };
    }
};

/// One loaded module as the manager describes it.
pub const Module = struct {
    instance: u32,
    name_at: u32,
    state: State,
    code_start: u32,
    code_size: u32,
    data_start: u32,
    data_size: u32,
};

/// The most of a name that is read; a longer one is cut short.
pub const longest = 32;

/// Fill `into` with the modules on the list whose head pointer lives at
/// `head_at`, in list order, and return how many. The walk stops back at
/// the first entry, at an entry without TXM_MODULE_ID, at a read that
/// fails, or when `into` is full, so a torn list never loops.
pub fn loaded(memory: anytype, head_at: u32, into: []Module) usize {
    const first = word(memory, head_at) orelse return 0;
    var at = first;
    var count: usize = 0;
    while (at != 0 and count < into.len) {
        into[count] = module(memory, at) orelse break;
        count += 1;
        at = word(memory, at +% offset.loaded_next) orelse break;
        if (at == first) break;
    }
    return count;
}

/// The instance at `at`, or null when it does not carry TXM_MODULE_ID or a
/// field cannot be read.
pub fn module(memory: anytype, at: u32) ?Module {
    if ((word(memory, at +% offset.id) orelse return null) != instance_id) return null;
    return .{
        .instance = at,
        .name_at = word(memory, at +% offset.name) orelse return null,
        .state = @fromBackingInt(@intCast(word(memory, at +% offset.state) orelse return null)),
        .code_start = word(memory, at +% offset.code_start) orelse return null,
        .code_size = word(memory, at +% offset.code_size) orelse return null,
        .data_start = word(memory, at +% offset.data_start) orelse return null,
        .data_size = word(memory, at +% offset.data_size) orelse return null,
    };
}

/// The module's name, or null when the pointer is zero or the bytes are
/// unreadable, empty or not text.
pub fn name(memory: anytype, entry: Module, buffer: *[longest]u8) ?[]const u8 {
    if (entry.name_at == 0) return null;
    var count: usize = 0;
    while (count < longest) : (count += 1) {
        const at = entry.name_at +% @as(u32, @intCast(count));
        if (!memory.read(at, buffer[count .. count + 1])) return null;
        const byte = buffer[count];
        if (byte == 0) break;
        if (byte < 0x20 or byte > 0x7E) return null;
    }
    if (count == 0) return null;
    return buffer[0..count];
}

fn word(memory: anytype, at: u32) ?u32 {
    var bytes: [4]u8 = undefined;
    if (!memory.read(at, &bytes)) return null;
    return std.mem.readInt(u32, &bytes, .little);
}
