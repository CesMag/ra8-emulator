//! Tests for src/session/txm_publish.zig: which module instances appeared
//! and left between two reads of the Module Manager's list, and the wire
//! kinds they go out as.
const std = @import("std");
const ra8 = @import("ra8");
const txm = ra8.session.txm_modules;
const publish = ra8.session.txm_publish;

fn module(instance: u32) txm.Module {
    return .{ .instance = instance, .name_at = 0, .state = .started, .code_start = 0, .code_size = 0, .data_start = 0, .data_size = 0 };
}

test "a first read reports every module loaded" {
    var known = publish.Known{};
    var into: [2 * publish.most]publish.Change = undefined;
    const now = [_]txm.Module{ module(0x2000_0100), module(0x2000_0600) };
    try std.testing.expectEqual(@as(usize, 2), publish.changes(&known, &now, &into));
    try std.testing.expectEqual(.module_loaded, into[0].kind);
    try std.testing.expectEqual(@as(u32, 0x2000_0100), into[0].instance);
    try std.testing.expectEqual(@as(u32, 0x2000_0600), into[1].instance);
}

test "an unchanged list reports nothing" {
    var known = publish.Known{};
    var into: [2 * publish.most]publish.Change = undefined;
    const now = [_]txm.Module{module(0x2000_0100)};
    _ = publish.changes(&known, &now, &into);
    try std.testing.expectEqual(@as(usize, 0), publish.changes(&known, &now, &into));
}

test "a module that leaves is unloaded and a new one is loaded" {
    var known = publish.Known{};
    var into: [2 * publish.most]publish.Change = undefined;
    const before = [_]txm.Module{ module(0x2000_0100), module(0x2000_0600) };
    _ = publish.changes(&known, &before, &into);
    const after = [_]txm.Module{ module(0x2000_0600), module(0x2000_0B00) };
    try std.testing.expectEqual(@as(usize, 2), publish.changes(&known, &after, &into));
    try std.testing.expectEqual(.module_loaded, into[0].kind);
    try std.testing.expectEqual(@as(u32, 0x2000_0B00), into[0].instance);
    try std.testing.expectEqual(.module_unloaded, into[1].kind);
    try std.testing.expectEqual(@as(u32, 0x2000_0100), into[1].instance);
}

test "an emptied list unloads everything" {
    var known = publish.Known{};
    var into: [2 * publish.most]publish.Change = undefined;
    const before = [_]txm.Module{module(0x2000_0100)};
    _ = publish.changes(&known, &before, &into);
    try std.testing.expectEqual(@as(usize, 1), publish.changes(&known, &.{}, &into));
    try std.testing.expectEqual(.module_unloaded, into[0].kind);
    try std.testing.expectEqual(@as(usize, 0), known.count);
}
