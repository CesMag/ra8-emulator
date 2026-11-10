//! The light build gate: file and function length checks.
//!
//! AGENTS.md asks for short files and short functions, and for the gate that
//! enforces it to stay light. This is the whole of it: count the lines in
//! every .zig file under the given paths, count the lines in every function
//! declared at the top level of a file or of a container, and report anything
//! over the limit. `zig fmt --check` is the other half and lives in build.zig,
//! where the build system already knows how to run it.
//!
//! The scan leans on the formatter: in zig-fmt'd source a function's closing
//! brace sits at the same column as the `fn` that opened it, so finding the
//! end of a function is a column comparison rather than a parse.
const std = @import("std");

/// The limits AGENTS.md promises. Both are overridable from the command line
/// so a one-off audit can ask a different question without a rebuild.
pub const limits = struct {
    pub const file_lines: usize = 400;
    pub const fn_lines: usize = 80;
};

pub const Function = struct {
    name: []const u8,
    start_line: usize,
    lines: usize,
};

/// Lines in `text`, counting a trailing newline as the end of its line and
/// not as the start of another.
pub fn countLines(text: []const u8) usize {
    if (text.len == 0) return 0;
    const breaks = std.mem.count(u8, text, "\n");
    return if (text[text.len - 1] == '\n') breaks else breaks + 1;
}

/// Walks the function declarations of one source file in order. Functions
/// nested inside another function are not reported separately; their lines
/// count towards the function that holds them.
pub const Scanner = struct {
    text: []const u8,
    pos: usize = 0,
    line_no: usize = 0,

    pub fn init(text: []const u8) Scanner {
        return .{ .text = text };
    }

    pub fn next(self: *Scanner) ?Function {
        while (self.nextLine()) |line| {
            const indent = indentOf(line);
            const name = declaredName(line[indent..]) orelse continue;
            const start = self.line_no;
            return .{ .name = name, .start_line = start, .lines = self.spanToClose(indent, start) };
        }
        return null;
    }

    fn nextLine(self: *Scanner) ?[]const u8 {
        if (self.pos >= self.text.len) return null;
        const end = std.mem.indexOfScalarPos(u8, self.text, self.pos, '\n') orelse self.text.len;
        const line = self.text[self.pos..end];
        self.pos = if (end < self.text.len) end + 1 else self.text.len;
        self.line_no += 1;
        return line;
    }

    /// Lines from the declaration through the brace that closes it. An
    /// unterminated function counts to the end of the file rather than
    /// swallowing the ones that follow it.
    fn spanToClose(self: *Scanner, indent: usize, start: usize) usize {
        while (self.nextLine()) |line| {
            if (indentOf(line) != indent) continue;
            const rest = line[indent..];
            if (rest.len > 0 and rest[0] == '}') return self.line_no - start + 1;
        }
        return self.line_no - start + 1;
    }
};

fn indentOf(line: []const u8) usize {
    var i: usize = 0;
    while (i < line.len and line[i] == ' ') i += 1;
    return i;
}

/// The name of the function `line` declares, or null when it declares none.
/// A prototype with no body (`extern fn`, a `fn` type) ends in `;` and is not
/// one.
pub fn declaredName(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimEnd(u8, line, " \r");
    if (std.mem.endsWith(u8, trimmed, ";")) return null;

    var words = std.mem.tokenizeScalar(u8, trimmed, ' ');
    var seen: usize = 0;
    while (words.next()) |word| : (seen += 1) {
        if (std.mem.eql(u8, word, "fn")) break;
        if (seen >= 3) return null;
        const qualifier = std.mem.eql(u8, word, "pub") or std.mem.eql(u8, word, "inline") or
            std.mem.eql(u8, word, "noinline") or std.mem.eql(u8, word, "export") or
            std.mem.eql(u8, word, "threadlocal");
        if (!qualifier) return null;
    } else return null;

    const after = words.rest();
    const open = std.mem.indexOfScalar(u8, after, '(') orelse return null;
    const name = std.mem.trim(u8, after[0..open], " ");
    return if (name.len == 0) null else name;
}

/// gate [--max-file N] [--max-fn N] <path>...
///
/// A path is a .zig file or a directory to walk. Every violation is printed;
/// the exit status is 1 when there was at least one.
pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(alloc);
    var buf: [4096]u8 = undefined;
    var err = std.Io.File.stderr().writer(init.io, &buf);
    var run: Run = .{ .alloc = alloc, .io = init.io, .out = &err.interface };
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--max-file") or std.mem.eql(u8, arg, "--max-fn")) {
            i += 1;
            if (i == argv.len) return error.MissingValue;
            const value = try std.fmt.parseInt(usize, argv[i], 10);
            if (arg[6] == 'f' and arg.len == 10) run.max_file = value else run.max_fn = value;
        } else {
            try run.walk(arg);
        }
    }
    if (run.scanned == 0) return error.NothingToCheck;
    try run.report();
    try run.out.flush();
    if (run.findings > 0) std.process.exit(1);
}

/// A directory the build fills in (caches, outputs, fetched packages) rather
/// than one the repository owns.
fn isFetched(path: []const u8) bool {
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    while (parts.next()) |part| {
        if (part[0] == '.' or std.mem.eql(u8, part, "zig-out") or std.mem.eql(u8, part, "zig-pkg") or std.mem.eql(u8, part, "node_modules")) return true;
    }
    return false;
}

/// One invocation: the limits it is holding files to and what it has seen.
const Run = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    max_file: usize = limits.file_lines,
    max_fn: usize = limits.fn_lines,
    scanned: usize = 0,
    findings: usize = 0,
    worst_file: usize = 0,
    worst_fn: usize = 0,

    fn walk(self: *Run, path: []const u8) !void {
        var dir = std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true }) catch |err| switch (err) {
            error.NotDir => return self.check(path),
            else => return err,
        };
        defer dir.close(self.io);

        var it = try dir.walk(self.alloc);
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            if (isFetched(entry.path)) continue;
            const full = try std.fs.path.join(self.alloc, &.{ path, entry.path });
            try self.check(full);
        }
    }

    fn check(self: *Run, path: []const u8) !void {
        const text = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.alloc, .limited(4 << 20));
        self.scanned += 1;

        const file_lines = countLines(text);
        self.worst_file = @max(self.worst_file, file_lines);
        if (file_lines > self.max_file) try self.flag(path, 0, "the file", file_lines, self.max_file);

        var scanner = Scanner.init(text);
        while (scanner.next()) |func| {
            self.worst_fn = @max(self.worst_fn, func.lines);
            if (func.lines > self.max_fn) try self.flag(path, func.start_line, func.name, func.lines, self.max_fn);
        }
    }

    fn flag(self: *Run, path: []const u8, line: usize, what: []const u8, lines: usize, max: usize) !void {
        self.findings += 1;
        if (line == 0) {
            try self.out.print("{s}: {s} is {d} lines, over the {d}-line limit\n", .{ path, what, lines, max });
        } else {
            try self.out.print("{s}:{d}: {s} is {d} lines, over the {d}-line limit\n", .{ path, line, what, lines, max });
        }
    }

    fn report(self: *Run) !void {
        if (self.findings > 0) {
            try self.out.print("gate: {d} over the limit in {d} files\n", .{ self.findings, self.scanned });
            return;
        }
        try self.out.print(
            "gate: {d} files, longest {d} lines (limit {d}), longest function {d} lines (limit {d})\n",
            .{ self.scanned, self.worst_file, self.max_file, self.worst_fn, self.max_fn },
        );
    }
};
