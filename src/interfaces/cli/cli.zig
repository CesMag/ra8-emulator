//! The command line: the flags the emulator takes and nothing else.
const std = @import("std");
const part = @import("ra8_chip").core.part;
const place = @import("ra8_session").place;
const pc_hits = @import("ra8_session").pc_hits;
const mem_dump = @import("ra8_session").mem_dump;
const gt911 = @import("ra8_components").gt911;
const world_flags = @import("world_flags.zig");
const max17048 = @import("ra8_components").max17048;
const sd_format = @import("ra8_components").sd_card.format;
const cpu_choice = @import("ra8_chip").core.cpu.choice;
const rtos_load = @import("ra8_session").rtos.load;
const request = @import("ra8_components").request;
pub const ctl = @import("ctl/ctl.zig");
const rtc_start = @import("ra8_session").rtc.start;
pub const usage = @import("usage.zig").text;
pub const card = @import("card/card.zig");
pub const console_output = @import("console_output.zig");
pub const host = @import("host/host.zig");
/// How many `--dump-sym` names one run will carry: the suite asks for at most
/// two (progress and failure counters), so this is a little room above that.
pub const dump_limit: usize = 8;
/// Instructions a run gets when nothing tells it when to stop. Long enough
/// for an app to reach whatever it prints and short enough that a sweep of
/// the whole corpus stays quick.
pub const budget: usize = 2_000_000;

/// Instructions a run gets when `--stop-sym` is watching a counter. A
/// watched run has an end of its own and reaches it early, so the budget is
/// only the ceiling on an app that never gets there: at the throughput this
/// model runs at, roughly 37 million instructions a second, that ceiling is
/// a few seconds rather than the fraction of one the default would give.
/// The suite's own apps need tens of millions (blink_ra8p1 reaches its fifth
/// tick at about 24 million), which the default budget ends ten times short
/// of, reporting a clean run for an app that had barely started.
pub const watched_budget: usize = 200_000_000;

/// Instructions one modelled millisecond costs at the fastest core clock
/// this corpus reaches, which is what bounds a `--ms` run.
///
/// The deadline itself is counted in SysTick periods, not here. Once SysTick
/// is armed, the Zig boundary scales this fixed cadence into cycles at the
/// image's rate. The ceiling keeps an image which never arms SysTick from
/// running forever; `budget` extra instructions leave room for boot and for
/// the boundary cut where firmware arms the timer.
pub const instructions_per_ms: usize = 1_000_000;

pub const Options = struct {
    path: []const u8,
    /// The budget `--instructions` asked for, or null to take whichever
    /// default fits the run. Resolved by `budget`, never read raw.
    instructions: ?usize = null,
    /// Which part the run models. Both share a register map; the RA8P1 also
    /// carries the Ethos-U55, so this decides whether that window answers.
    part: part.Part = .ra8d2,
    /// CMSAMON.CMS and SFSAMON.SFS, the Secure code MRAM and SiP flash in
    /// 32 KB units. Null leaves the part unprogrammed (RA8EMU-428).
    cms: ?u9 = null,
    sfs: ?u9 = null,
    /// Format the card on the SPI line before the run. Null leaves it the
    /// way it has always come up: blank, with no volume on it at all.
    sd_new: ?sd_format.Kind = null,
    /// The volume label that format gives the card.
    sd_label: []const u8 = card.setup.default_label,
    /// The card's size in MiB. Null keeps the image's own default.
    sd_size_mb: ?u32 = null,
    /// Raw SDHC image file to attach to the SPI card.
    sd_path: ?[]const u8 = null,
    sd_save: bool = false, // `--sd-save`: write the card back over sd_path at the end
    sdhi: card.setup.Sdhi = .{}, // `--sd-image PATH` [`--sd-writable`]: the SDHI card
    /// A disk in the HS jack's USB stick: "blank" or a raw image path.
    usb_disk: ?[]const u8 = null,
    /// `--usbip PORT`: export the FS device to usbip hosts during the run.
    usbip: ?u16 = null,
    /// `--frame-out PATH`: the panel as a PNG at the end of the run (RA8EMU-73).
    frame_out: ?[]const u8 = null,
    panel_only: bool = false, // `--panel-only`: only the glass, at its own size
    frames: @import("frames/args.zig").Options = .{},
    audio: @import("audio_out.zig").Options = .{}, // `--audio-out`, `--audio-rate`
    rtc_start: ?@import("ra8_session").rtc.start.Start = null,
    speed: ?u64 = null, // `--speed`/`--realtime`: thousandths of 1x; null runs flat out
    run_for: bool = false, // `--run-for`: a watchdog reset ends the run (RA8EMU-186)
    idle_skip: bool = true, // a sleeping core runs to its next edge; `--no-idle-skip` steps it
    usb_loop: bool = false, // cable the HS host jack to the board's own FS device jack
    trace_sd: bool = false, // write one line per SD command to stderr
    state: @import("state_args.zig").Options = .{}, // `--save-state`, `--load-state` (RA8EMU-696)
    console: bool = false, // `--console`: stream finished SCI console lines to stdout
    console_reply: @import("ra8_chip").periph.sci.reply.Reply = .{}, // RA8EMU-626
    dump_sd: ?u32 = null, // print this card block back as hex once the run is over
    faults: ?[]const u8 = null, // `--faults FILE`: hardware changes at virtual times (RA8EMU-207)
    /// Contacts queued on the touch panel, one drained per frame read.
    touches: [gt911.queue_depth]gt911.Contact = @splat(gt911.Contact{}),
    touch_count: usize = 0,
    touch_in: ?[]const u8 = null, // `--touch @PATH`: a file or FIFO of host touches, one per line
    input_script: ?[]const u8 = null, // `--input-script PATH`: timed taps, swipes, presses, buttons
    /// What the fuel gauge says is in the battery; the gauge range-checks it.
    battery: max17048.Battery = .{},
    /// Fit the Click module, so the IMU and the fuel gauge answer at all.
    click: bool = false,
    board_profile: ?[]const u8 = null,
    detach_c6: bool = false,
    /// `--net-record DIR` / `--net-replay DIR`: the C6's host traffic (RA8EMU-560).
    net_tape: ?@import("ra8_components").esp_tape.Spec = null,
    /// `--attach NAME@ENDPOINT`: extra catalog models, in the order asked.
    attaches: [request.max]request.Request = undefined,
    attach_count: usize = 0,
    /// A refused access raises the precise BusFault it raises on silicon
    /// instead of ending the run; src/chip/core/cpu/exception/bus_fault.zig. On by default;
    /// `--no-bus-errors` brings back the old end-of-run fault report.
    bus_errors: bool = true,
    /// The Zig core runs from formed blocks (RA8EMU-408); `--no-blocks` steps.
    blocks: bool = true,
    /// Globals to read out of RAM once the run is over, in the order asked.
    dump: [dump_limit][]const u8 = @splat(""),
    dump_count: usize = 0,
    /// A global to watch, and the value that ends the run once it reaches
    /// it. Null watches nothing and the run goes to its instruction budget.
    stop_symbol: ?[]const u8 = null,
    stop_at: u32 = 0,
    /// Console text that ends the run once a finished line contains it
    /// (`--until`), the bench's uart_scrape stop. Null waits for none.
    until: ?[]const u8 = null,
    /// Where to stop, spelled the way `place.parse` reads it: a function,
    /// an address, or either with an offset. Null stops at nothing and the
    /// run goes to its instruction budget.
    break_place: ?[]const u8 = null,
    /// Which arrival at `break_place` ends the run. One is the first.
    break_arrival: u32 = 1,
    /// Print the core registers after the run.
    dump_regs: bool = false,
    /// End the run at the first undefined instruction, before it executes.
    /// Off by default: the sweep reports, it does not decide.
    stop_on_undefined: bool = false,
    /// `--dump-mem` places read after the run, in order (RA8EMU-488).
    dump_mem: [mem_dump.limit]mem_dump.Ask = undefined,
    dump_mem_count: usize = 0,
    /// A place whose stores to record, as the command line spelled it.
    /// Null watches nothing and costs the run nothing.
    watch_place: ?[]const u8 = null,
    /// `--trace-rtos`: record ThreadX thread switches. src/session/rtos.hook.zig.
    trace_rtos: bool = false,
    /// `--trace-rtos-out FILE`: also write the trace there (RA8EMU-345).
    trace_rtos_out: ?[]const u8 = null,
    /// `--report json`: the end-of-run report as one JSON line (RA8EMU-347).
    report_json: bool = false,
    /// `--cpu-load`: CPU load per thread and ISR, per core, from the same
    /// hook. src/session/rtos.report.zig.
    cpu_load: bool = false,
    /// `ctl cpu-load`: print just the load object after a one-shot image run.
    ctl_cpu_load: bool = false,
    /// Count instructions and modelled cycles by ELF function.
    profile: bool = false,
    /// Write folded function counts to this path as well as printing them.
    profile_folded: ?[]const u8 = null,
    /// `--profile-thread`: fold only the samples taken while this RTOS
    /// thread (its TCB address, as `--trace-rtos` prints it) was running;
    /// 0 takes those taken while none was (RA8EMU-954).
    profile_thread: ?u32 = null,
    /// `--cpu-load-from` / `--cpu-load-to`: the virtual instructions the
    /// load is charged over. Either one turns `--cpu-load` on.
    cpu_load_window: rtos_load.Window = .{},
    /// `--taken-in`: a function to catch every exception taken inside.
    /// src/session/taken_in.zig says why a tally cannot answer that.
    taken_in_place: ?[]const u8 = null,
    /// `--count-pc`: instruction addresses to count executions of, in the
    /// order they were given. src/session/pc_hits.zig says why a counter
    /// that measures nothing but the execution is worth having.
    count_pc: [pc_hits.limits.places]u32 = @splat(0),
    /// How many of `count_pc` were actually given.
    count_pc_len: usize = 0,
    /// `--chunk`: how many instructions between two boundaries, overriding
    /// the run's own cadence. For asking whether a result depends on where
    /// the boundaries fall. src/chip/core/cadence.zig carries the default.
    chunk_instructions: ?u32 = null,
    /// The second core's image, when the run is a two-core one.
    cpu1_path: ?[]const u8 = null,
    /// `--ns`: the Non-Secure companion image, loaded beside the main one.
    ns_path: ?[]const u8 = null,
    /// `--cpu`: which CPU runs the image; src/chip/core/cpu/choice.zig.
    cpu: cpu_choice.Choice = .zig,
    /// Milliseconds of modelled time the run is allowed, counted in SysTick
    /// periods. Null is untimed and the run goes to its instruction budget.
    ms: ?u64 = null,
    /// `--camera-source KIND[:ARG]`: where the CEU's pixels come from (RA8EMU-525).
    camera: @import("ra8_host").camera.source_spec.Spec = .{},

    /// The names asked for, as a slice rather than the fixed array.
    pub fn dumps(self: *const Options) []const []const u8 {
        return self.dump[0..self.dump_count];
    }

    /// The `--dump-mem` places, in command-line order.
    pub fn memDumps(self: *const Options) []const mem_dump.Ask {
        return self.dump_mem[0..self.dump_mem_count];
    }

    /// How many instructions this run gets. An explicit `--instructions`
    /// always wins; otherwise a run with a counter to watch gets the
    /// watched budget and every other run gets the default.
    ///
    /// `watching` is whether a counter was actually resolved, not whether
    /// the flag was spelled: a `--stop-sym` naming a symbol the image does
    /// not carry watches nothing, and spending the larger budget on it
    /// would cost seconds per app to reach the same verdict.
    ///
    /// A timed run sizes its own ceiling from the deadline it was given, so
    /// asking for more milliseconds buys more instructions to spend them in
    /// rather than running into a number set for some other app.
    /// The load window when a flag asked for the RTOS trace, else null.
    pub fn rtosWanted(self: *const Options) ?rtos_load.Window {
        if (!self.trace_rtos and !self.cpu_load) return null;
        return self.cpu_load_window;
    }

    pub fn budgetFor(self: *const Options, watching: bool) usize {
        if (self.instructions) |asked| return asked;
        if (self.ms) |milliseconds| return ceilingFor(milliseconds);
        return if (watching) watched_budget else budget;
    }
};

/// The instruction ceiling a deadline of `milliseconds` gets: one period
/// over, so the boot before SysTick arms never ends a 1 GHz run a period
/// short (RA8EMU-526). It saturates rather than wraps into a short budget.
pub fn ceilingFor(milliseconds: u64) usize {
    if (milliseconds == 0) return 0;
    const window = milliseconds *| @as(u64, instructions_per_ms);
    const wanted = window +| @as(u64, budget);
    return std.math.cast(usize, wanted) orelse std.math.maxInt(usize);
}

pub fn parse(argv: []const []const u8) !Options {
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "ctl")) return parseCtl(argv);
    return parseRun(argv);
}

fn parseRun(argv: []const []const u8) !Options {
    if (argv.len < 2) return error.MissingImage;
    var options = Options{ .path = argv[1] };
    var index: usize = 2;
    while (index < argv.len) : (index += 1) {
        if (try world_flags.parse(&options, argv, &index)) continue;
        if (try parseDebug(&options, argv, &index)) continue;
        if (std.mem.eql(u8, argv[index], "--instructions")) {
            index += 1;
            if (index >= argv.len) return error.MissingValue;
            options.instructions = try std.fmt.parseInt(usize, argv[index], 10);
        } else if (std.mem.eql(u8, argv[index], "--dump-sym")) {
            index += 1;
            if (index >= argv.len) return error.MissingValue;
            if (options.dump_count >= options.dump.len) return error.TooManyDumps;
            options.dump[options.dump_count] = argv[index];
            options.dump_count += 1;
        } else if (std.mem.eql(u8, argv[index], "--until")) {
            index += 1;
            if (index >= argv.len) return error.MissingValue;
            options.until = argv[index];
        } else if (std.mem.eql(u8, argv[index], "--stop-sym")) {
            if (index + 2 >= argv.len) return error.MissingValue;
            options.stop_symbol = argv[index + 1];
            options.stop_at = try std.fmt.parseInt(u32, argv[index + 2], 10);
            index += 2;
        } else if (std.mem.eql(u8, argv[index], "--break-sym") or
            std.mem.eql(u8, argv[index], "--break-at"))
        {
            index += 1;
            if (index >= argv.len) return error.MissingValue;
            options.break_place = argv[index];
            // The count is optional, so it is taken only when the next
            // argument is one. A place that is itself a number is written
            // 0x-prefixed or not, and either way it has already been
            // taken by the line above; the flag that may follow instead
            // always starts with a dash.
            if (index + 1 < argv.len) {
                if (std.fmt.parseInt(u32, argv[index + 1], 0) catch null) |nth| {
                    if (nth == 0) return error.BadValue;
                    options.break_arrival = nth;
                    index += 1;
                }
            }
        } else if (std.mem.eql(u8, argv[index], "--ms")) {
            index += 1;
            if (index >= argv.len) return error.MissingValue;
            options.ms = try std.fmt.parseInt(u64, argv[index], 10);
        } else if (std.mem.eql(u8, argv[index], "--part") or
            std.mem.eql(u8, argv[index], "--device"))
        {
            index += 1;
            if (index >= argv.len) return error.MissingValue;
            options.part = part.Part.parse(argv[index]) orelse return error.UnknownPart;
        } else if (std.mem.eql(u8, argv[index], "--dump-mem")) {
            index += 1;
            if (index >= argv.len) return error.MissingValue;
            if (options.dump_mem_count >= options.dump_mem.len) return error.TooManyDumps;
            var ask: mem_dump.Ask = .{ .spec = argv[index] };
            if (index + 1 < argv.len) {
                if (std.fmt.parseInt(u32, argv[index + 1], 0) catch null) |count| {
                    if (count == 0) return error.BadValue;
                    ask.words = count;
                    index += 1;
                }
            }
            options.dump_mem[options.dump_mem_count] = ask;
            options.dump_mem_count += 1;
        } else return error.UnknownFlag;
    }
    return options;
}

/// Parse the available one-shot CPU-load command through the ordinary run
/// options, translating its shorter window flags.
fn parseCtl(argv: []const []const u8) !Options {
    const args = try ctl.args.parse(argv);
    var options = try parseRun(args.slice());
    options.ctl_cpu_load = true;
    options.cpu_load = true;
    return options;
}

/// The flags that inspect a run rather than shape the board, split out of
/// `parse` to keep each chain inside the length gate. True when the flag was
/// one of these and `index` has been walked past any value it took.
fn parseDebug(options: *Options, argv: []const []const u8, index: *usize) !bool {
    if (try @import("frames/args.zig").parse(&options.frames, argv, index)) return true;
    if (try @import("state_args.zig").parse(&options.state, argv, index)) return true;
    const flag = argv[index.*];
    if (std.mem.eql(u8, flag, "--cpu1")) {
        options.cpu1_path = try world_flags.next(argv, index);
    } else if (std.mem.eql(u8, flag, "--ns")) {
        options.ns_path = try world_flags.next(argv, index);
    } else if (std.mem.eql(u8, flag, "--watch")) {
        options.watch_place = try world_flags.next(argv, index);
    } else if (std.mem.eql(u8, flag, "--frame-out")) {
        options.frame_out = try world_flags.next(argv, index);
    } else if (std.mem.eql(u8, flag, "--panel-only")) {
        options.panel_only = true;
    } else if (std.mem.eql(u8, flag, "--trace-rtos")) {
        options.trace_rtos = true;
    } else if (std.mem.eql(u8, flag, "--trace-rtos-out")) {
        options.trace_rtos = true;
        options.trace_rtos_out = try world_flags.next(argv, index);
    } else if (std.mem.eql(u8, flag, "--report")) {
        options.report_json = try reportForm(try world_flags.next(argv, index));
    } else if (std.mem.eql(u8, flag, "--cpu-load")) {
        options.cpu_load = true;
    } else if (std.mem.eql(u8, flag, "--profile")) {
        options.profile = true;
    } else if (std.mem.eql(u8, flag, "--profile-folded")) {
        options.profile = true;
        options.profile_folded = try world_flags.next(argv, index);
    } else if (std.mem.eql(u8, flag, "--profile-thread")) {
        options.profile_thread = try std.fmt.parseInt(u32, try world_flags.next(argv, index), 0);
    } else if (std.mem.eql(u8, flag, "--cpu-load-from")) {
        options.cpu_load = true;
        options.cpu_load_window.from = try std.fmt.parseInt(u64, try world_flags.next(argv, index), 0);
    } else if (std.mem.eql(u8, flag, "--cpu-load-to")) {
        options.cpu_load = true;
        options.cpu_load_window.to = try std.fmt.parseInt(u64, try world_flags.next(argv, index), 0);
    } else if (std.mem.eql(u8, flag, "--taken-in")) {
        options.taken_in_place = try world_flags.next(argv, index);
    } else if (std.mem.eql(u8, flag, "--count-pc")) {
        const at = try std.fmt.parseInt(u32, try world_flags.next(argv, index), 0);
        if (options.count_pc_len >= options.count_pc.len) {
            std.debug.print("--count-pc: a run can count at most {d} addresses\n", .{options.count_pc.len});
            return error.BadValue;
        }
        options.count_pc[options.count_pc_len] = at;
        options.count_pc_len += 1;
    } else if (std.mem.eql(u8, flag, "--chunk")) {
        const width = try std.fmt.parseInt(u32, try world_flags.next(argv, index), 0);
        if (width == 0) return error.BadValue;
        options.chunk_instructions = width;
    } else if (std.mem.eql(u8, flag, "--cpu")) {
        options.cpu = cpu_choice.Choice.parse(try world_flags.next(argv, index)) orelse return error.BadValue;
    } else if (std.mem.eql(u8, flag, "--dump-regs")) {
        options.dump_regs = true;
    } else if (std.mem.eql(u8, flag, "--stop-on-undefined")) {
        options.stop_on_undefined = true;
    } else return false;
    return true;
}

/// `--report text` or `--report json`; anything else is refused.
fn reportForm(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "json")) return true;
    if (std.mem.eql(u8, value, "text")) return false;
    return error.BadValue;
}
