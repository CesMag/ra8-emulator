//! Frozen image admission owns file bytes until both cores have loaded.
const std = @import("std");
const ra8 = @import("ra8");
const Images = ra8.rpc.served_initial.Images;
const root = ra8.session.history_root;
const gpa = std.testing.allocator;
const io = std.testing.io;

fn recorded() root.Root {
    return .{ .snapshot_version = 1, .elf0 = .{ .identity = root.identity("first"), .bytes = "first" }, .elf1 = .{ .identity = root.identity("second"), .bytes = "second" } };
}

test "admitted file bytes stay frozen when both source paths change" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "first", .data = "first" });
    try temp.dir.writeFile(io, .{ .sub_path = "second", .data = "second" });
    const first = try temp.dir.realPathFileAlloc(io, "first", gpa);
    defer gpa.free(first);
    const second = try temp.dir.realPathFileAlloc(io, "second", gpa);
    defer gpa.free(second);
    var images = Images.init(gpa, io, first, null, .{ .path = second });
    defer images.deinit();
    try images.check(recorded());
    try temp.dir.writeFile(io, .{ .sub_path = "first", .data = "changed" });
    try temp.dir.writeFile(io, .{ .sub_path = "second", .data = "changed" });
    try images.check(recorded());
    try std.testing.expectEqualStrings("first", images.firstBytes().?);
    try std.testing.expectEqualStrings("second", images.second.?.bytes);
}

test "image presence and both identities refuse incompatible startup" {
    var absent = Images.init(gpa, io, "missing", null, null);
    defer absent.deinit();
    try std.testing.expectError(error.ImageMismatch, absent.check(recorded()));
    var first = Images.init(gpa, io, "missing", "wrong", .{ .bytes = "second" });
    defer first.deinit();
    try std.testing.expectError(error.ImageMismatch, first.check(recorded()));
    var second = Images.init(gpa, io, "missing", "first", .{ .bytes = "wrong" });
    defer second.deinit();
    try std.testing.expectError(error.ImageMismatch, second.check(recorded()));
    var missing = Images.init(gpa, io, "missing", null, .{ .bytes = "second" });
    defer missing.deinit();
    try std.testing.expectError(error.FileNotFound, missing.check(recorded()));
}
