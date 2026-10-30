//! CPU1 startup ownership, before the history root is frozen.
const std = @import("std");
const Cpu1 = @import("ra8_session").cpu1.bringup.Cpu1;
const Served = @import("served_setup.zig").Served;

pub const Image = union(enum) { path: []const u8, bytes: []const u8 };

pub fn open(self: *Served, image: Image) !void {
    if (self.second != null) return error.SecondCoreAlreadyOpen;
    if (self.owner.session().root != null) return error.HistoryAlreadyRooted;
    const cpu1 = try self.gpa.create(Cpu1);
    errdefer self.gpa.destroy(cpu1);
    cpu1.* = .{};
    switch (image) {
        .path => |path| try cpu1.open(self.gpa, self.io, std.Io.Dir.cwd(), &self.owner, path),
        .bytes => |bytes| try cpu1.openBytes(self.gpa, &self.owner, bytes),
    }
    self.second = cpu1;
}

pub fn close(self: *Served) void {
    if (self.second) |cpu1| {
        cpu1.close(self.gpa);
        self.gpa.destroy(cpu1);
        self.second = null;
    }
}
