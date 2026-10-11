//! The file picker's handoff (RA8EMU-959): SDL answers the picker through a
//! callback on a thread of its choosing, and src/interfaces/gui/sdl/dialog.zig
//! carries the path across SDL's event queue to the window's own thread.
//! These run on SDL's event subsystem alone, with no window and no picker:
//! the callback is called the way SDL calls it. Built only by
//! `zig build gui-test -Dgui`.
const std = @import("std");
const sdl = @import("gui_sdl");

const c = sdl.c;
const dialog = sdl.dialog;

/// Drain SDL's queue through `picker`, returning the last path it took.
fn drain(picker: *dialog.Picker) ?[]const u8 {
    var found: ?[]const u8 = null;
    var ev: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&ev)) {
        if (picker.take(&ev)) |path| found = path;
    }
    return found;
}

fn choose(picker: *const dialog.Picker, path: ?[*:0]const u8) void {
    const list = [_][*c]const u8{ path, null };
    dialog.chosen(@ptrFromInt(picker.kind), &list, 0);
}

test "a chosen file crosses the event queue and comes out as its path" {
    try std.testing.expect(c.SDL_Init(c.SDL_INIT_EVENTS));
    defer c.SDL_Quit();
    var picker = dialog.Picker.init();
    defer picker.deinit();
    try std.testing.expect(picker.kind >= c.SDL_EVENT_USER);
    try std.testing.expectEqual(@as(?[]const u8, null), drain(&picker));
    choose(&picker, "/tmp/ra8 images/app.elf");
    try std.testing.expectEqualStrings("/tmp/ra8 images/app.elf", drain(&picker).?);
    try std.testing.expectEqual(@as(?[]const u8, null), drain(&picker));
}

test "a later choice replaces the path held, and the one before it is let go" {
    try std.testing.expect(c.SDL_Init(c.SDL_INIT_EVENTS));
    defer c.SDL_Quit();
    var picker = dialog.Picker.init();
    defer picker.deinit();
    choose(&picker, "first.elf");
    const first = drain(&picker).?;
    try std.testing.expectEqualStrings("first.elf", first);
    choose(&picker, "second.axf");
    try std.testing.expectEqualStrings("second.axf", drain(&picker).?);
}

test "an error or a cancelled picker posts nothing" {
    try std.testing.expect(c.SDL_Init(c.SDL_INIT_EVENTS));
    defer c.SDL_Quit();
    var picker = dialog.Picker.init();
    defer picker.deinit();
    dialog.chosen(@ptrFromInt(picker.kind), null, 0);
    choose(&picker, null);
    try std.testing.expectEqual(@as(?[]const u8, null), drain(&picker));
}

test "another event of SDL's is not taken for a choice, and a picker with no event type takes none" {
    try std.testing.expect(c.SDL_Init(c.SDL_INIT_EVENTS));
    defer c.SDL_Quit();
    var picker = dialog.Picker.init();
    defer picker.deinit();
    var other = std.mem.zeroes(c.SDL_Event);
    other.type = c.SDL_EVENT_QUIT;
    try std.testing.expectEqual(@as(?[]const u8, null), picker.take(&other));
    var shut: dialog.Picker = .{ .kind = 0 };
    var mine = std.mem.zeroes(c.SDL_Event);
    try std.testing.expectEqual(@as(?[]const u8, null), shut.take(&mine));
}
