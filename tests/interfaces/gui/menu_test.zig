//! Host tests for the menu model (RA8EMU-967): the bar's menus and items,
//! shortcut text per OS, Quit moving to the macOS app menu, shortcut
//! lookup, and the enabled rules.
const std = @import("std");
const gui_app = @import("gui_app");
const menu = gui_app.menu;

test "the bar has File, Run, View and Board in that order" {
    try std.testing.expectEqual(@as(usize, 4), menu.bar.len);
    try std.testing.expectEqualStrings("File", menu.bar[0].title);
    try std.testing.expectEqualStrings("Run", menu.bar[1].title);
    try std.testing.expectEqualStrings("View", menu.bar[2].title);
    try std.testing.expectEqualStrings("Board", menu.bar[3].title);
}

test "the Board menu lists the shipped profiles and the OS picker" {
    // The board, then one panel per shipped panel, then the picker.
    try std.testing.expectEqual(@as(usize, 1 + menu.board_profiles.panels.len + 1), menu.board.len);
    const board_item = menu.board[0];
    try std.testing.expectEqualStrings("Board: EK-RA8D2", board_item.label);
    try std.testing.expect(board_item.action.eql(.{ .choice = .{ .kind = .board, .stem = "ek_ra8d2" } }));
    const panel_item = menu.board[1];
    try std.testing.expect(panel_item.action.eql(.{ .choice = .{ .kind = .panel, .stem = "" } }));
    const eink = menu.board[menu.board.len - 2];
    try std.testing.expect(eink.action.eql(.{ .choice = .{ .kind = .panel, .stem = "sample_eink" } }));
    const picker = menu.board[menu.board.len - 1];
    try std.testing.expectEqualStrings("Open Profile...", picker.label);
    try std.testing.expect(picker.action.eql(.{ .command = .open_profile }));
    try std.testing.expect(picker.divided);
}

test "File opens an ELF, closes it and quits" {
    try std.testing.expectEqualStrings("Open ELF...", menu.file[0].label);
    try std.testing.expect(menu.file[0].action.eql(.{ .command = .open_elf }));
    try std.testing.expectEqualStrings("Reload", menu.file[1].label);
    try std.testing.expect(menu.file[1].action.eql(.{ .command = .reload }));
    try std.testing.expectEqual(@as(?menu.Shortcut, null), menu.file[1].shortcut);
    try std.testing.expectEqualStrings("Close", menu.file[2].label);
    try std.testing.expect(menu.file[2].action.eql(.{ .command = .close }));
    try std.testing.expectEqualStrings("Settings...", menu.file[3].label);
    try std.testing.expect(menu.file[3].action.eql(.{ .command = .settings }));
    try std.testing.expectEqual(@as(u8, ','), menu.file[3].shortcut.?.key);
    try std.testing.expect(menu.file[4].action.eql(.{ .command = .quit }));
    try std.testing.expect(menu.file[4].divided);
}

test "View toggles every pane kind but empty" {
    try std.testing.expectEqual(std.enums.values(gui_app.pane_layout.Kind).len, menu.view.len);
    try std.testing.expectEqualStrings("Board", menu.view[0].label);
    try std.testing.expect(menu.view[0].action.eql(.{ .toggle = .board }));
    try std.testing.expectEqualStrings("Disassembly", menu.view[6].label);
    try std.testing.expectEqual(@as(u8, '7'), menu.view[6].shortcut.?.key);
    try std.testing.expectEqualStrings("Call stack", menu.view[7].label);
    try std.testing.expectEqual(@as(u8, '8'), menu.view[7].shortcut.?.key);
    try std.testing.expectEqualStrings("Timeline", menu.view[8].label);
    try std.testing.expect(menu.view[8].action.eql(.{ .toggle = .timeline }));
    try std.testing.expectEqual(@as(u8, '9'), menu.view[8].shortcut.?.key);
    // The tenth pane kind keys nothing: Ctrl/Cmd+1..9 are the window's digits.
    try std.testing.expectEqualStrings("Source", menu.view[9].label);
    try std.testing.expectEqualStrings("Locals", menu.view[10].label);
    try std.testing.expect(menu.view[10].action.eql(.{ .toggle = .locals }));
    try std.testing.expectEqual(@as(?menu.Shortcut, null), menu.view[10].shortcut);
    try std.testing.expectEqualStrings("Memory Map", menu.view[11].label);
    try std.testing.expect(menu.view[11].action.eql(.{ .toggle = .map }));
    try std.testing.expectEqualStrings("State Diff", menu.view[12].label);
    try std.testing.expect(menu.view[13].action.eql(.{ .toggle = .branches }));
    try std.testing.expectEqualStrings("Branch Tree", menu.view[13].label);
    try std.testing.expect(menu.view[9].action.eql(.{ .toggle = .source }));
    try std.testing.expectEqual(@as(?menu.Shortcut, null), menu.view[9].shortcut);
    try std.testing.expectEqualStrings("Host Metrics", menu.view[14].label);
    try std.testing.expect(menu.view[14].action.eql(.{ .toggle = .host_metrics }));
    try std.testing.expectEqualStrings("Device Metrics", menu.view[15].label);
    try std.testing.expect(menu.view[15].action.eql(.{ .toggle = .device_metrics }));
    for (menu.view) |item| switch (item.action) {
        .toggle => |kind| try std.testing.expect(kind != .empty),
        .command, .choice, .recent => {},
    };
}

test "View's full-screen entry under a divider with no key" {
    const item = menu.view[menu.view.len - 1];
    try std.testing.expectEqualStrings("Enter Full Screen", item.label);
    try std.testing.expect(item.action.eql(.{ .command = .toggle_fullscreen }));
    try std.testing.expect(item.divided);
    try std.testing.expectEqual(@as(?menu.Shortcut, null), item.shortcut);
    // Full screen is window-level: it fires whether or not an ELF is loaded.
    try std.testing.expect(menu.enabled(item.action, menu.State{}));
}

test "full-screen label follows the window's state" {
    const item = menu.view[menu.view.len - 1];
    try std.testing.expectEqualStrings("Enter Full Screen", menu.label(item, menu.State{}));
    try std.testing.expectEqualStrings("Exit Full Screen", menu.label(item, .{ .fullscreen = true }));
    try std.testing.expectEqualStrings("Board", menu.label(menu.view[0], .{ .fullscreen = true }));
}

test "no two items share a shortcut" {
    for (menu.bar, 0..) |a_menu, a_at| {
        for (a_menu.items, 0..) |a, a_item| {
            const a_key = a.shortcut orelse continue;
            for (menu.bar, 0..) |b_menu, b_at| {
                for (b_menu.items, 0..) |b, b_item| {
                    if (a_at == b_at and a_item == b_item) continue;
                    const b_key = b.shortcut orelse continue;
                    try std.testing.expect(a_key.key != b_key.key or a_key.shift != b_key.shift);
                }
            }
        }
    }
}

test "shortcut text uses Cmd on macOS and Ctrl elsewhere" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("Cmd+O", try menu.text(.{ .key = 'O' }, .macos, &buf));
    try std.testing.expectEqualStrings("Ctrl+O", try menu.text(.{ .key = 'O' }, .windows, &buf));
    try std.testing.expectEqualStrings("Ctrl+Shift+R", try menu.text(.{ .key = 'R', .shift = true }, .linux, &buf));
}

test "a buffer too small for the text is an error" {
    var buf: [3]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, menu.text(.{ .key = 'O' }, .linux, &buf));
}

test "Quit leaves File on macOS only" {
    const quit = menu.file[4];
    try std.testing.expect(!menu.shows(quit, .macos));
    try std.testing.expect(menu.shows(quit, .windows));
    try std.testing.expect(menu.shows(quit, .linux));
    try std.testing.expect(menu.shows(menu.file[0], .macos));
}

test "find maps a key and shift to its action in any case" {
    const bar: []const menu.Menu = &menu.bar;
    try std.testing.expect(menu.find(bar, 'o', false).?.eql(.{ .command = .open_elf }));
    try std.testing.expect(menu.find(bar, 'R', false).?.eql(.{ .command = .run }));
    try std.testing.expect(menu.find(bar, 'r', true).?.eql(.{ .command = .reset }));
    try std.testing.expect(menu.find(bar, '3', false).?.eql(.{ .toggle = .camera }));
    try std.testing.expect(menu.find(bar, '8', false).?.eql(.{ .toggle = .stack }));
    try std.testing.expectEqual(@as(?menu.Action, null), menu.find(bar, 'Z', false));
    try std.testing.expectEqual(@as(?menu.Action, null), menu.find(bar, 'O', true));
}

test "nothing loaded: only Open, Quit and the view toggles fire" {
    const idle = menu.State{};
    try std.testing.expect(menu.enabled(.{ .command = .open_elf }, idle));
    try std.testing.expect(menu.enabled(.{ .command = .quit }, idle));
    try std.testing.expect(menu.enabled(.{ .toggle = .memory }, idle));
    inline for (.{ .close, .run, .pause, .step, .reset }) |command| {
        try std.testing.expect(!menu.enabled(.{ .command = command }, idle));
    }
}

test "loaded and halted: run and step fire, pause does not" {
    const halted = menu.State{ .loaded = true };
    try std.testing.expect(menu.enabled(.{ .command = .run }, halted));
    try std.testing.expect(menu.enabled(.{ .command = .step }, halted));
    try std.testing.expect(menu.enabled(.{ .command = .reset }, halted));
    try std.testing.expect(menu.enabled(.{ .command = .close }, halted));
    try std.testing.expect(!menu.enabled(.{ .command = .pause }, halted));
}

test "running: pause fires, run and step do not" {
    const running = menu.State{ .loaded = true, .running = true };
    try std.testing.expect(menu.enabled(.{ .command = .pause }, running));
    try std.testing.expect(menu.enabled(.{ .command = .reset }, running));
    try std.testing.expect(!menu.enabled(.{ .command = .run }, running));
    try std.testing.expect(!menu.enabled(.{ .command = .step }, running));
}

test "eql tells commands and toggles apart" {
    const run: menu.Action = .{ .command = .run };
    try std.testing.expect(run.eql(.{ .command = .run }));
    try std.testing.expect(!run.eql(.{ .command = .pause }));
    try std.testing.expect(!run.eql(.{ .toggle = .board }));
}
