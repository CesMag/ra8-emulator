//! Public owner for a firmware image, its Zig core, board, and debug session.
const std = @import("std");
const elf = @import("ra8_board").image.elf;
const part = @import("ra8_chip").core.part;
const BoardBus = @import("ra8_chip").core.cpu.board_bus.BoardBus;
const mpu_check = @import("ra8_chip").core.cpu.board_bus.mpu_check;
const cpu_mod = @import("ra8_chip").core.cpu.cpu;
const NvicSource = @import("ra8_chip").core.cpu.exception.nvic_source.NvicSource;
const QuietSource = @import("ra8_chip").core.cpu.exception.quiet_source.QuietSource;
const Guest = @import("ra8_chip").core.cpu.memory.guest.Guest;
const memory_load = @import("ra8_chip").core.cpu.memory.load;
const read_image = @import("ra8_board").image.load;
const Board = @import("ra8_board").board.Board;
const option_memory = @import("ra8_chip").periph.iwdt.option_memory;
const Reboot = @import("ra8_chip").core.reboot.Reboot;
const session_plug = @import("../board_plug.zig");
const session_faults = @import("../board_faults/board_faults.zig");
const board_boundary = @import("../board_boundary.zig");
const chunk_clock = @import("../chunk_clock.zig");
const session_events = @import("../board_events.zig");
const second_core = @import("ra8_chip").core.second_core;
const session_display = @import("../board_display.zig");
const session_state = @import("../board_state.zig");
const files = @import("files.zig");
const debug_session = @import("../session.zig");
const session_api = @import("../api.zig");
const stop_machine = @import("../stop_machine.zig");
const step_hook = @import("../step_hook.zig");
const symbols = @import("../symbols.zig");
const txm_modules = @import("../txm_modules.zig");
const txm_publish = @import("../txm_publish.zig");
const txm_debug = @import("../txm_debug.zig");
const watch_bus = @import("../watch_bus.zig");
const rtos_hook = step_hook.rtos_hook;
const rtos_publish = step_hook.rtos_publish;
const Cpu0 = @import("ra8_board").cpu0_store.Cpu0;
const decode = @import("ra8_chip").core.cpu.decode;
pub const stacks = @import("stacks.zig");

pub const limits = struct {
    pub const max_elf_bytes = 64 * 1024 * 1024;
    pub const max_input_bytes = 1024 * 1024;
};

pub const Options = struct {
    elf_path: []const u8,
    device: part.Part = .ra8p1,
    input_script: ?[]const u8 = null,
    settle_window_ns: u64 = 50_000_000,
};

const LoaderState = struct {
    allocator: std.mem.Allocator,
    cpu: [2]?*cpu_mod.Cpu = .{ null, null },
    memory: [2]?Guest = .{ null, null },
    /// An owned copy of each core's last loaded image, for the memory map
    /// (RA8EMU-794); replaced on every load.
    loaded: [2]?[]u8 = .{ null, null },

    fn load(context: *anyopaque, core: session_api.Core, bytes: []const u8) anyerror!void {
        const self: *LoaderState = @ptrCast(@alignCast(context));
        const image = try elf.Image.init(bytes);
        const index = @backingInt(core);
        const cpu = self.cpu[index] orelse return error.CoreNotAttached;
        const memory = self.memory[index] orelse return error.CoreNotAttached;
        // The same map, option-window claim and write a `--cpu zig` run
        // loads with, so option-setting segments land (RA8EMU-760).
        const loaded = try read_image.read(image);
        _ = try memory_load.image(memory, loaded.image());
        try cpu.reset(image.vectorBase() orelse return error.NoVectorTable);
        const copy = try self.allocator.dupe(u8, bytes);
        if (self.loaded[index]) |old| self.allocator.free(old);
        self.loaded[index] = copy;
    }

    fn deinit(self: *LoaderState) void {
        for (self.loaded) |kept| if (kept) |bytes| self.allocator.free(bytes);
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    image: elf.Image,
    board: Board,
    cpu0: Cpu0,
    memory: BoardBus,
    /// CPU0's MPU check, armed as a plain run arms it (boot.zig).
    check: mpu_check.Check,
    machine: stop_machine.Machine,
    driver: step_hook.Driver,
    watching: watch_bus.WatchBus,
    cpu: cpu_mod.Cpu,
    /// CPU0's decoded instructions and formed blocks, as a plain run keeps
    /// them (boot.zig runOn), so a session runs at a plain run's pace
    /// (RA8EMU-1120).
    decoded: decode.cache.DecodeCache,
    formed: *decode.block_cache.BlockCache,
    pending: NvicSource,
    quiet: QuietSource,
    loading: LoaderState,
    session: session_api.Session,
    plugs_arena: std.heap.ArenaAllocator,
    plugs: session_plug.Plugs,
    faults: session_faults.Faults,
    edge: board_boundary.BoardBoundary,
    chunk: chunk_clock.ChunkClock,
    files: session_state.Files,
    state_file: files.StateFile,
    reboot: Reboot,
    display: session_display.Host,
    tracer: ?rtos_hook.Tracer,
    listener: rtos_hook.zig.Listener,
    publisher: rtos_publish.Publisher,
    module_watch: txm_publish.Watcher,
    /// Set by watchModules and pairModules; the state is built without defaults.
    modules: txm_debug.Table,

    fn advance(context: *anyopaque, max_ns: u64) anyerror!void {
        const self: *State = @ptrCast(@alignCast(context));
        const selected = self.session.currentCore();
        try self.session.switchTo(.cpu0);
        defer self.session.switchTo(selected) catch {};
        const started = self.board.time.base.now();
        const deadline = started +| max_ns;
        const budget = self.session.live.budget;
        defer self.session.live.budget = budget;
        while (self.board.time.base.now() < deadline) {
            const remaining = self.board.time.base.cyclesUntil(deadline);
            self.session.live.budget = @max(1, @min(budget, remaining));
            const before = self.board.time.base.now();
            _ = try self.session.run(.cpu0, .cont);
            if (self.board.time.base.now() <= before) return error.NoVirtualProgress;
        }
    }
};

/// Owns the heap-stable emulator state. Do not copy a live Harness value.
pub const Harness = struct {
    state: *State,

    pub fn session(self: *Harness) *session_api.Session {
        return &self.state.session;
    }

    pub fn image(self: *const Harness) elf.Image {
        return self.state.image;
    }

    /// The image a core last loaded (the opened one, until a session load
    /// replaces it), or null when nothing loaded on that core.
    pub fn loadedImage(self: *const Harness, core: session_api.Core) ?elf.Image {
        const bytes = self.state.loading.loaded[@backingInt(core)] orelse return null;
        return elf.Image.init(bytes) catch null;
    }

    pub fn board(self: *Harness) *Board {
        return &self.state.board;
    }

    pub fn guest(self: *Harness) Guest {
        return self.state.cpu0.own();
    }

    pub fn primaryCpu(self: *Harness) *cpu_mod.Cpu {
        return &self.state.cpu;
    }

    pub fn attachCore(self: *Harness, core: session_api.Core, cpu: *cpu_mod.Cpu, core_guest: Guest) void {
        const index = @backingInt(core);
        self.state.loading.cpu[index] = cpu;
        self.state.loading.memory[index] = core_guest;
        self.state.session.attachBoard(core, self.state.board.ticker(), core_guest);
    }

    /// Publish CPU0's ThreadX switches and exception entry and return on
    /// the session's event stream (RA8EMU-346). The tracer sits in front of
    /// the core and is drained at each chunk boundary. Stamps are CPU0's
    /// retired instructions, one cycle each, at the time base's rate. False
    /// when the image has no ThreadX; call once, after open.
    pub fn traceRtos(self: *Harness) bool {
        const state = self.state;
        state.tracer = rtos_hook.resolve(state.image, .{}) orelse return false;
        const tracer = &state.tracer.?;
        tracer.now = &state.board.time.base.retired;
        tracer.trace.fine = &state.cpu.retired;
        state.listener = .{ .tracer = tracer };
        state.cpu.bus = state.listener.onBus(state.cpu.bus);
        if (state.cpu.source) |inner| state.cpu.source = state.listener.onSource(inner);
        state.publisher = .{ .trace = &tracer.trace, .stream = &state.session.event_stream, .inner = state.session.live.boundary, .time = &state.board.time.base };
        state.session.live.boundary = state.publisher.hook();
        return true;
    }

    /// Turn RTOS tracing on unless it already is; false when the image
    /// has no ThreadX current-thread pointer to trace.
    pub fn traceIfRtos(self: *Harness) bool {
        if (self.state.tracer != null) return true;
        return self.traceRtos();
    }

    /// Sample CPU0's call stacks into `into` (RA8EMU-833), named by the
    /// opened image and tagged with the thread when traceRtos() found one.
    /// `into` stays put until `unsampleStacks` or deinit.
    pub fn sampleStacks(self: *Harness, into: *stacks.Stacks) void {
        const state = self.state;
        const trace = if (state.tracer) |*found| &found.trace else null;
        into.watch(0, &state.cpu, &state.image, &state.board.time.base, trace);
    }

    pub fn unsampleStacks(self: *Harness, into: *stacks.Stacks) void {
        into.unwatch(0, &self.state.cpu);
    }

    /// Publish ThreadX module loads, unloads and faults on the session's event
    /// stream (RA8EMU-1139), read from the Module Manager's list at each
    /// chunk boundary. False when the image has no Module Manager; call
    /// once, after open.
    pub fn watchModules(self: *Harness) bool {
        const state = self.state;
        const head = symbols.addressOf(state.image, txm_modules.list_symbol) orelse return false;
        state.module_watch = .{ .head_at = head, .memory = .{ .guest = self.guest() }, .stream = &state.session.event_stream, .inner = state.session.live.boundary, .time = &state.board.time.base };
        state.module_watch.fault_at = symbols.addressOf(state.image, txm_publish.fault_symbol);
        state.modules = .{ .pairs = &.{} };
        state.module_watch.table = &state.modules;
        state.session.live.boundary = state.module_watch.hook();
        return true;
    }

    /// The module ELFs `--app FILE.ra8app=MODULE.elf` paired (RA8EMU-1141),
    /// placed as their modules load; `pairs` outlives the harness.
    pub fn pairModules(self: *Harness, pairs: []const txm_debug.Pair) *txm_debug.Table {
        self.state.modules = .{ .pairs = pairs };
        return &self.state.modules;
    }

    /// Snapshot and restore of this run's file (RA8EMU-768).
    /// The board's plug hook, which also keeps what is fitted where.
    pub fn plugs(self: *Harness) *session_plug.Plugs {
        return &self.state.plugs;
    }

    pub fn stateFiles(self: *Harness) session_state.Hook {
        return self.state.state_file.hook();
    }

    /// Let the boundary tick CPU1's board edge and take its reset requests.
    pub fn bindSecond(self: *Harness, second: *second_core.Second, second_guest: Guest) void {
        self.state.edge.second = second;
        self.state.edge.second_memory = second_guest;
    }

    pub fn deinit(self: *Harness) void {
        const state = self.state;
        state.display.deinit();
        state.plugs.deinit();
        state.plugs_arena.deinit();
        state.cpu0.close();
        dropBlocks(state.formed);
        state.board.deinit();
        state.loading.deinit();
        state.allocator.free(state.bytes);
        state.allocator.destroy(state);
        self.* = undefined;
    }
};

/// Open and load one ELF with the board ticker and display attached.
pub fn open(allocator: std.mem.Allocator, io: std.Io, options: Options) !Harness {
    if (options.settle_window_ns == 0) return error.InvalidSettleWindow;
    const state = try allocator.create(State);
    errdefer allocator.destroy(state);
    state.allocator = allocator;
    state.bytes = try std.Io.Dir.cwd().readFileAlloc(io, options.elf_path, allocator, .limited(limits.max_elf_bytes));
    errdefer allocator.free(state.bytes);
    state.image = try elf.Image.init(state.bytes);
    state.board = Board.init(allocator);
    errdefer state.board.deinit();
    state.board.part = options.device;
    state.board.clock.pace.mode = .virtual;
    try loadInput(allocator, io, &state.board, options.input_script);
    state.cpu0 = .{};
    state.tracer = null;
    errdefer state.cpu0.close();
    _ = try state.cpu0.attachStore(&state.board, state.image);
    const vector = state.image.vectorBase() orelse return error.NoVectorTable;
    option_memory.apply(&state.board.heartbeat, state.cpu0.own());
    state.memory = .{ .memory = .{ .store = .{ .store = &state.cpu0.store.?, .initiator = .cpu0 } }, .periph = &state.board.bus, .scs = .{ .partitions = &state.board.partitions, .regions = &state.board.regions, .clears = &state.board.clears } };
    // The MPU check, as a plain run arms it (boot.zig), before any view
    // copies the direct path: without it a session core refused nothing, so
    // a ThreadX module's out-of-region store landed (RA8EMU-1148).
    state.check = .{ .unit = &state.board.regions, .state = &state.cpu.banked.current };
    state.memory.armCheck(&state.check);
    state.machine = .{};
    state.driver = .{ .machine = &state.machine };
    state.watching = .{ .inner = state.memory.view(), .driver = &state.driver };
    state.pending = .{};
    state.quiet = .{ .inner = state.pending.source(), .memory = state.watching.view() };
    state.cpu = .{ .bus = state.quiet.bus(), .source = state.quiet.source(), .quiet = &state.quiet };
    state.cpu.mpu = &state.check;
    state.pending.banked = &state.cpu.banked;
    state.pending.clear_due = &state.quiet.clear_due;
    state.decoded = .{};
    state.cpu.decoded = &state.decoded;
    state.formed = try formBlocks();
    errdefer dropBlocks(state.formed);
    state.cpu.blocks = state.formed;
    // CPACR and the FP context words reach the core's FP state, as in a
    // plain run (boot.zig); otherwise every FP instruction is NOCP (RA8EMU-950).
    state.memory.scs.fp = &state.cpu.fp;
    try state.cpu.reset(vector);
    state.loading = .{ .allocator = allocator };
    errdefer state.loading.deinit();
    state.loading.cpu[0] = &state.cpu;
    state.loading.memory[0] = state.cpu0.own();
    state.session = .{ .live = .{ .core = .{ .cpu = &state.cpu }, .machine = &state.machine, .budget = debug_session.limits.default_budget, .watch = &state.watching } };
    state.session.attachInputScript(&state.board.input_script);
    state.session.attachLoader(.{ .context = &state.loading, .loadFn = LoaderState.load });
    state.plugs_arena = std.heap.ArenaAllocator.init(allocator);
    errdefer state.plugs_arena.deinit();
    state.plugs = session_plug.Plugs.init(&state.board, state.plugs_arena.allocator());
    state.session.attachPlugs(state.plugs.hook());
    state.faults = session_faults.Faults.init(&state.board, state.plugs_arena.allocator());
    state.session.attachFaults(&state.faults);
    state.reboot = .{ .vector_base = vector };
    state.board.reboot = &state.reboot;
    state.chunk = .{ .cpu = &state.cpu, .mark = state.cpu.retired };
    state.session.event_sources.chunk = &state.chunk;
    state.edge = .{ .board = &state.board, .core = state.cpu0.own(), .cpu = &state.cpu, .reboot = &state.reboot, .selected = &state.session.live.index, .chunk = &state.chunk };
    state.session.live.boundary = state.edge.hook();
    state.files = .{ .store = &state.cpu0.store.?, .cpu = &state.cpu, .board = &state.board, .edge = &state.edge };
    state.state_file = .{ .allocator = allocator, .io = io, .files = &state.files };
    session_events.attach(&state.board, &state.session);
    state.session.attachBoard(.cpu0, state.board.ticker(), state.cpu0.own());
    state.display = session_display.Host.init(allocator, &state.board, .{ .context = state, .advanceFn = State.advance });
    errdefer state.display.deinit();
    state.display.settled.window_ns = options.settle_window_ns;
    state.display.watch.events = &state.session.event_sources;
    state.session.attachDisplay(state.display.interface());
    try state.session.load(.cpu0, state.bytes);
    return .{ .state = state };
}

fn loadInput(allocator: std.mem.Allocator, io: std.Io, board: *Board, path: ?[]const u8) !void {
    const named = path orelse return;
    const text = try std.Io.Dir.cwd().readFileAlloc(io, named, allocator, .limited(limits.max_input_bytes));
    defer allocator.free(text);
    try board.input_script.parse(text);
}

/// A block cache watching every store, so a write over code drops its
/// blocks (code_lines.zig).
fn formBlocks() !*decode.block_cache.BlockCache {
    const cache = try std.heap.page_allocator.create(decode.block_cache.BlockCache);
    errdefer std.heap.page_allocator.destroy(cache);
    cache.init();
    try decode.code_lines.watch(&cache.lines);
    return cache;
}

fn dropBlocks(cache: *decode.block_cache.BlockCache) void {
    decode.code_lines.unwatch(&cache.lines);
    std.heap.page_allocator.destroy(cache);
}
