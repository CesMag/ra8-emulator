//! One core as the debugger reads it (RA8EMU-105): the Zig core behind
//! src/session/zig/core.zig. The session and its views read registers and
//! memory through this. The union has one arm, so a second kind of core can join without touching the callers.
const bus = @import("ra8_chip").core.cpu.bus;
const zig_core = @import("zig/core.zig");

pub const Cortex = @import("ra8_chip").core.cpu.cortex.Cortex;
/// Only memory can fail: the Zig core's register file always answers.
pub const Error = bus.Error;

pub const View = union(enum) {
    zig: zig_core.ZigCore,

    pub fn register(self: View, which: Cortex) Error!u32 {
        return switch (self) {
            .zig => |core| core.register(which),
        };
    }

    pub fn stack(self: View) zig_core.StackMarks {
        return switch (self) {
            .zig => |core| core.stack(),
        };
    }

    pub fn setRegister(self: View, which: Cortex, value: u32) Error!void {
        switch (self) {
            .zig => |core| core.setRegister(which, value),
        }
    }

    pub fn read(self: View, address: u32, into: []u8) Error!void {
        return switch (self) {
            .zig => |core| core.read(address, into),
        };
    }

    pub fn readWord(self: View, address: u32) Error!u32 {
        return switch (self) {
            .zig => |core| core.readWord(address),
        };
    }

    pub fn write(self: View, address: u32, bytes: []const u8) Error!void {
        return switch (self) {
            .zig => |core| core.write(address, bytes),
        };
    }
};
