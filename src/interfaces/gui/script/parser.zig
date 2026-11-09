//! Line-by-line parser for GUI interaction scripts (RA8EMU-1120).
const std = @import("std");
const action_mod = @import("action.zig");

pub const Action = action_mod.Action;
pub const Item = action_mod.Item;
pub const TimeSpec = action_mod.TimeSpec;
pub const Target = action_mod.Target;
pub const NamedTarget = action_mod.NamedTarget;

pub const ParseError = error{
    BadTiming,
    BadAction,
    BadTarget,
    BadCoordinates,
    InvalidSyntax,
    InvalidNumber,
    OutOfMemory,
};

pub const Script = struct {
    items: std.ArrayListUnmanaged(Item) = .empty,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Script) void {
        for (self.items.items) |item| {
            if (item.action == .type_text) {
                self.allocator.free(item.action.type_text);
            }
        }
        self.items.deinit(self.allocator);
    }
};

pub fn parse(allocator: std.mem.Allocator, text: []const u8) ParseError!Script {
    var script = Script{ .allocator = allocator };
    errdefer script.deinit();

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or std.mem.startsWith(u8, line, "//")) continue;
        const item = try parseLine(allocator, line);
        try script.items.append(allocator, item);
    }
    return script;
}

pub const TimeKeyword = enum {
    frame,
    virtual,
    emulated,
    board,
    wall,
    real,
};

fn parseLine(allocator: std.mem.Allocator, line: []const u8) ParseError!Item {
    var tokens = std.mem.tokenizeAny(u8, line, " \t");
    const first = tokens.next() orelse return error.InvalidSyntax;
    if (!std.mem.eql(u8, first, "at")) {
        if (std.mem.eql(u8, first, "quit") or std.mem.eql(u8, first, "exit")) {
            return .{ .at = .{ .frame = 0 }, .action = .quit };
        }
        return error.BadAction;
    }

    const time_tok = tokens.next() orelse return error.BadTiming;
    const at: TimeSpec = if (std.meta.stringToEnum(TimeKeyword, time_tok)) |kw| switch (kw) {
        .frame => blk: {
            const frame_tok = tokens.next() orelse return error.BadTiming;
            const frame = std.fmt.parseInt(u32, frame_tok, 10) catch return error.BadTiming;
            break :blk .{ .frame = frame };
        },
        .virtual, .emulated, .board => blk: {
            const dur_tok = tokens.next() orelse return error.BadTiming;
            break :blk .{ .virtual_ns = try parseTime(dur_tok) };
        },
        .wall, .real => blk: {
            const dur_tok = tokens.next() orelse return error.BadTiming;
            break :blk .{ .wall_ns = try parseTime(dur_tok) };
        },
    } else .{ .time_ns = try parseTime(time_tok) };

    const action_tok = tokens.next() orelse return error.BadAction;
    const act = try parseAction(allocator, action_tok, &tokens, line);
    return .{ .at = at, .action = act };
}

pub fn parseTime(tok: []const u8) ParseError!u64 {
    if (std.mem.endsWith(u8, tok, "ms")) {
        const num = std.fmt.parseInt(u64, tok[0 .. tok.len - 2], 10) catch return error.BadTiming;
        return num * std.time.ns_per_ms;
    }
    if (std.mem.endsWith(u8, tok, "us")) {
        const num = std.fmt.parseInt(u64, tok[0 .. tok.len - 2], 10) catch return error.BadTiming;
        return num * std.time.ns_per_us;
    }
    if (std.mem.endsWith(u8, tok, "ns")) {
        return std.fmt.parseInt(u64, tok[0 .. tok.len - 2], 10) catch error.BadTiming;
    }
    if (std.mem.endsWith(u8, tok, "s")) {
        const num_str = tok[0 .. tok.len - 1];
        const val = std.fmt.parseFloat(f64, num_str) catch return error.BadTiming;
        if (val < 0) return error.BadTiming;
        const ns_per_s_f64: f64 = @floatFromInt(std.time.ns_per_s);
        return @intFromFloat(val * ns_per_s_f64);
    }
    const num = std.fmt.parseInt(u64, tok, 10) catch return error.BadTiming;
    return num * std.time.ns_per_ms;
}

fn parseAction(allocator: std.mem.Allocator, act_tok: []const u8, tokens: *std.mem.TokenIterator(u8, .any), line: []const u8) ParseError!Action {
    if (std.mem.eql(u8, act_tok, "click")) {
        return parseClick(tokens);
    }
    if (std.mem.eql(u8, act_tok, "drag")) {
        return parseDrag(tokens);
    }
    if (std.mem.eql(u8, act_tok, "type")) {
        return parseType(allocator, line);
    }
    if (std.mem.eql(u8, act_tok, "key")) {
        return parseKey(tokens);
    }
    if (std.mem.eql(u8, act_tok, "quit") or std.mem.eql(u8, act_tok, "exit")) {
        return .quit;
    }
    return error.BadAction;
}

/// The branch tree and state diff targets a script may click.
fn historyTarget(tok: []const u8) ?action_mod.NamedTarget {
    const names = [_]struct { text: []const u8, target: action_mod.NamedTarget }{
        .{ .text = "tree:node0", .target = .tree_node_0 },
        .{ .text = "tree:node1", .target = .tree_node_1 },
        .{ .text = "tree:node2", .target = .tree_node_2 },
        .{ .text = "diff:earlier", .target = .diff_earlier },
        .{ .text = "diff:later", .target = .diff_later },
    };
    for (names) |n| if (std.mem.eql(u8, tok, n.text)) return n.target;
    return null;
}

fn parseClick(tokens: *std.mem.TokenIterator(u8, .any)) ParseError!Action {
    const target_tok = tokens.next() orelse return error.BadCoordinates;
    if (std.mem.eql(u8, target_tok, "bar:run")) {
        return .{ .click = .{ .named = .bar_run } };
    }
    if (std.mem.eql(u8, target_tok, "bar:pause")) {
        return .{ .click = .{ .named = .bar_pause } };
    }
    if (std.mem.eql(u8, target_tok, "bar:step")) {
        return .{ .click = .{ .named = .bar_step } };
    }
    if (std.mem.eql(u8, target_tok, "bar:step-over")) {
        return .{ .click = .{ .named = .bar_step_over } };
    }
    if (std.mem.eql(u8, target_tok, "bar:step-out")) {
        return .{ .click = .{ .named = .bar_step_out } };
    }
    if (std.mem.eql(u8, target_tok, "bar:speed")) {
        return .{ .click = .{ .named = .bar_speed } };
    }
    if (std.mem.eql(u8, target_tok, "bar:seek")) {
        return .{ .click = .{ .named = .bar_seek } };
    }
    if (std.mem.eql(u8, target_tok, "bar:track")) {
        return .{ .click = .{ .named = .bar_track } };
    }
    if (std.mem.eql(u8, target_tok, "camera:allow_once")) {
        return .{ .click = .{ .named = .camera_allow_once } };
    }
    if (std.mem.eql(u8, target_tok, "camera:always")) {
        return .{ .click = .{ .named = .camera_always } };
    }
    if (std.mem.eql(u8, target_tok, "camera:cam")) {
        return .{ .click = .{ .named = .camera_cam } };
    }
    if (std.mem.eql(u8, target_tok, "camera:grd")) {
        return .{ .click = .{ .named = .camera_grd } };
    }
    if (std.mem.eql(u8, target_tok, "board:sw1")) {
        return .{ .click = .{ .named = .board_sw1 } };
    }
    if (std.mem.eql(u8, target_tok, "board:sw2")) {
        return .{ .click = .{ .named = .board_sw2 } };
    }
    if (std.mem.eql(u8, target_tok, "banner:confirm")) {
        return .{ .click = .{ .named = .banner_confirm } };
    }
    if (std.mem.eql(u8, target_tok, "banner:cancel")) {
        return .{ .click = .{ .named = .banner_cancel } };
    }
    if (historyTarget(target_tok)) |named| return .{ .click = .{ .named = named } };
    if (std.mem.eql(u8, target_tok, "board:touch")) {
        const x_tok = tokens.next() orelse return error.BadCoordinates;
        const y_tok = tokens.next() orelse return error.BadCoordinates;
        const x = std.fmt.parseInt(u16, x_tok, 10) catch return error.BadCoordinates;
        const y = std.fmt.parseInt(u16, y_tok, 10) catch return error.BadCoordinates;
        return .{ .click = .{ .touch = .{ .x = x, .y = y } } };
    }
    if (std.mem.indexOfScalar(u8, target_tok, ':') != null) {
        return error.BadTarget;
    }

    const x = std.fmt.parseInt(i32, target_tok, 10) catch return error.BadTarget;
    const y_tok = tokens.next() orelse return error.BadCoordinates;
    const y = std.fmt.parseInt(i32, y_tok, 10) catch return error.BadCoordinates;
    return .{ .click = .{ .coord = .{ .x = x, .y = y } } };
}

fn parseDrag(tokens: *std.mem.TokenIterator(u8, .any)) ParseError!Action {
    const fx_tok = tokens.next() orelse return error.BadCoordinates;
    const fy_tok = tokens.next() orelse return error.BadCoordinates;
    const tx_tok = tokens.next() orelse return error.BadCoordinates;
    const ty_tok = tokens.next() orelse return error.BadCoordinates;
    const dur_tok = tokens.next() orelse return error.BadTiming;

    const from_x = std.fmt.parseInt(i32, fx_tok, 10) catch return error.BadCoordinates;
    const from_y = std.fmt.parseInt(i32, fy_tok, 10) catch return error.BadCoordinates;
    const to_x = std.fmt.parseInt(i32, tx_tok, 10) catch return error.BadCoordinates;
    const to_y = std.fmt.parseInt(i32, ty_tok, 10) catch return error.BadCoordinates;

    const dur_clean = if (std.mem.endsWith(u8, dur_tok, "ms")) dur_tok[0 .. dur_tok.len - 2] else dur_tok;
    const duration_ms = std.fmt.parseInt(u32, dur_clean, 10) catch return error.BadTiming;

    return .{ .drag = .{
        .from_x = from_x,
        .from_y = from_y,
        .to_x = to_x,
        .to_y = to_y,
        .duration_ms = duration_ms,
    } };
}

fn parseType(allocator: std.mem.Allocator, line: []const u8) ParseError!Action {
    const quote_start = std.mem.indexOfScalar(u8, line, '"') orelse return error.InvalidSyntax;
    const quote_end = std.mem.lastIndexOfScalar(u8, line, '"') orelse return error.InvalidSyntax;
    if (quote_end <= quote_start) return error.InvalidSyntax;
    const raw_text = line[quote_start + 1 .. quote_end];
    const duped = allocator.dupe(u8, raw_text) catch return error.OutOfMemory;
    return .{ .type_text = duped };
}

fn parseKey(tokens: *std.mem.TokenIterator(u8, .any)) ParseError!Action {
    const key_tok = tokens.next() orelse return error.BadTarget;
    var name = key_tok;
    var shift = false;
    var primary = false;
    while (std.mem.indexOfScalar(u8, name, '+')) |sep| {
        const modifier = name[0..sep];
        if (std.ascii.eqlIgnoreCase(modifier, "shift")) {
            shift = true;
        } else if (std.ascii.eqlIgnoreCase(modifier, "ctrl") or std.ascii.eqlIgnoreCase(modifier, "control")) {
            primary = true;
        } else {
            return error.BadTarget;
        }
        name = name[sep + 1 ..];
    }
    if (name.len == 0) return error.BadTarget;
    const plain: ?u32 = if (std.ascii.eqlIgnoreCase(name, "Return") or std.ascii.eqlIgnoreCase(name, "Enter"))
        0x0D
    else if (std.ascii.eqlIgnoreCase(name, "Escape") or std.ascii.eqlIgnoreCase(name, "Esc"))
        0x1B
    else if (std.ascii.eqlIgnoreCase(name, "Space"))
        0x20
    else if (std.ascii.eqlIgnoreCase(name, "Tab"))
        0x09
    else if (std.ascii.eqlIgnoreCase(name, "Backspace"))
        0x08
    else
        null;
    const extended: ?u32 = if (std.ascii.eqlIgnoreCase(name, "F5"))
        action_mod.KeyCode.f5
    else if (std.ascii.eqlIgnoreCase(name, "F10"))
        action_mod.KeyCode.f10
    else if (std.ascii.eqlIgnoreCase(name, "F11"))
        action_mod.KeyCode.f11
    else if (std.ascii.eqlIgnoreCase(name, "Home"))
        action_mod.KeyCode.home
    else if (std.ascii.eqlIgnoreCase(name, "End"))
        action_mod.KeyCode.end
    else if (std.ascii.eqlIgnoreCase(name, "Left"))
        action_mod.KeyCode.left
    else if (std.ascii.eqlIgnoreCase(name, "Right"))
        action_mod.KeyCode.right
    else
        null;
    const code = plain orelse extended orelse {
        if (name.len == 1) return .{ .key = .{ .code = name[0], .shift = shift, .primary = primary } };
        return error.BadTarget;
    };
    return .{ .key = .{ .code = code, .shift = shift, .primary = primary } };
}
