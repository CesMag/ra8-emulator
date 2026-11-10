import { Injectable, signal, computed, OnDestroy } from '@angular/core';
import { Subject } from 'rxjs';
import {
  RA8RpcClient,
  Core,
  Topic,
  Register,
  RunMode,
  InputKind,
  DirtyRect,
  Stopped,
  UartEvent,
  SessionEvent,
  TraceEvent,
  TransportEvent,
  MetricsReport,
  BoardParts,
  Backtrace,
  DisasmRow,
  StackReport,
  BranchItem,
  ForkStatus,
  ForkReason,
  Direction,
  FrameStatusResult,
  DecodedDiff,
  EventKind,
} from 'ra8-rpc-client';

export type ConnectionState = 'disconnected' | 'connecting' | 'connected' | 'error';
export type ExecutionStatus = 'stopped' | 'running' | 'halted';
export type CoreInspectionMode = 'split' | 'cpu0' | 'cpu1';
export type ActorKind = 'human' | 'agent';

export interface ConsoleEntry {
  text: string;
  time: string;
  isInput: boolean;
  core: Core;
}

export interface RtosTaskSummary {
  key: string;
  core: Core;
  thread: number;
  name: string;
  switches: number;
  sharePercent: number;
}

export interface ActivityLogEntry {
  id: number;
  time: string;
  core: Core;
  category: 'session' | 'bus' | 'fault' | 'rtos' | 'transport';
  label: string;
  detail: string;
}

export interface DagCheckpointNode {
  id: string;
  branchId: number;
  r: bigint;
  pcCpu0: number;
  pcCpu1: number;
  label: string;
  badge: string; // '', 'W', 'T', 'B', 'K', 'P', 'E'
  actor: ActorKind;
  timestamp: string;
  registersCpu0: Record<string, number>;
  registersCpu1: Record<string, number>;
}

export interface DagLaneView {
  id: number;
  parent: number;
  name: string;
  forkR: bigint;
  endR: bigint;
  reason: ForkReason;
  reasonBadge: string;
  actor: ActorKind;
  isLive: boolean;
  isPinned: boolean;
  nodes: DagCheckpointNode[];
}

export function rgb565ToCssHex(rgb565: number): string {
  const r5 = (rgb565 >> 11) & 0x1f;
  const g6 = (rgb565 >> 5) & 0x3f;
  const b5 = rgb565 & 0x1f;
  const r = Math.round((r5 * 255) / 31);
  const g = Math.round((g6 * 255) / 63);
  const b = Math.round((b5 * 255) / 31);
  return `#${r.toString(16).padStart(2, '0')}${g.toString(16).padStart(2, '0')}${b.toString(16).padStart(2, '0')}`;
}

export function forkReasonBadge(reason: ForkReason): string {
  switch (reason) {
    case ForkReason.Writes: return 'W';
    case ForkReason.Taps: return 'T';
    case ForkReason.Buttons: return 'B';
    case ForkReason.Keystrokes: return 'K';
    case ForkReason.PlugUnplugFault: return 'P';
    case ForkReason.SkipBkpt: return 'E';
    case ForkReason.Load: return 'L';
    default: return '';
  }
}

@Injectable({
  providedIn: 'root'
})
export class EmulatorService implements OnDestroy {
  private client: RA8RpcClient | null = null;
  private metricsTimer: any = null;
  private decoder = new TextDecoder();
  private nextLogId = 1;
  private lastVirtualNsSample: bigint | null = null;
  private lastWallMsSample: number | null = null;
  private rtosSwitchMap = new Map<string, { core: Core; thread: number; name: string; count: number }>();

  // Connection & session status
  public readonly connectionState = signal<ConnectionState>('disconnected');
  public readonly executionStatus = signal<ExecutionStatus>('stopped');
  public readonly serverUrl = signal<string>('ws://127.0.0.1:4567');
  public readonly errorMessage = signal<string | null>(null);
  public readonly serverCaps = signal<number>(0);

  // Dual-core & NPU silicon concurrency state
  public readonly inspectionMode = signal<CoreInspectionMode>('split');
  public readonly activeCore = signal<Core>(Core.Cpu0);
  public readonly cpu0Attached = signal<boolean>(true);
  public readonly cpu1Attached = signal<boolean>(false);
  public readonly cpu0StateLabel = signal<string>('STOPPED');
  public readonly cpu1StateLabel = signal<string>('UNATTACHED');
  public readonly npuStateLabel = signal<string>('STANDBY');
  public readonly lastStop = signal<Stopped | null>(null);

  // Board front-panel & 8-bit LED state
  public readonly boardParts = signal<BoardParts | null>(null);
  public readonly ledStates = signal<boolean[]>([false, false, false, false, false, false, false, false]);
  public readonly speedMilli = signal<number>(0);

  // Per-core registers, authoritative disassembly, backtrace, stack, and breakpoint ID maps
  public readonly cpu0Registers = signal<Record<string, number>>({});
  public readonly cpu0PrevRegisters = signal<Record<string, number>>({});
  public readonly cpu1Registers = signal<Record<string, number>>({});
  public readonly cpu1PrevRegisters = signal<Record<string, number>>({});

  public readonly cpu0Disasm = signal<DisasmRow[]>([]);
  public readonly cpu1Disasm = signal<DisasmRow[]>([]);
  public readonly cpu0Pc = signal<number>(0);
  public readonly cpu1Pc = signal<number>(0);

  public readonly cpu0Backtrace = signal<Backtrace | null>(null);
  public readonly cpu1Backtrace = signal<Backtrace | null>(null);
  public readonly cpu0Stack = signal<StackReport | null>(null);
  public readonly cpu1Stack = signal<StackReport | null>(null);

  public readonly cpu0Breakpoints = signal<Map<number, number>>(new Map());
  public readonly cpu1Breakpoints = signal<Map<number, number>>(new Map());

  // Compatibility computed aliases for focused single-core helpers
  public readonly registers = computed(() =>
    this.activeCore() === Core.Cpu1 ? this.cpu1Registers() : this.cpu0Registers()
  );
  public readonly previousRegisters = computed(() =>
    this.activeCore() === Core.Cpu1 ? this.cpu1PrevRegisters() : this.cpu0PrevRegisters()
  );

  // Host & Guest Telemetry + 60s Sparklines + Pacing Ratio
  public readonly metrics = signal<MetricsReport | null>(null);
  public readonly virtualTimeNs = signal<bigint>(0n);
  public readonly pacingRatio = signal<number | null>(null);
  public readonly hostCpuHistory = signal<number[]>([]);
  public readonly hostRssHistory = signal<number[]>([]);
  public readonly rtosTasks = signal<RtosTaskSummary[]>([]);

  // Time-Travel & Right-Opening Execution DAG
  public readonly dagDrawerOpen = signal<boolean>(false);
  public readonly actorMode = signal<ActorKind>('human');
  public readonly backendBranches = signal<BranchItem[]>([]);
  public readonly forkStatus = signal<ForkStatus | null>(null);
  public readonly frameStatus = signal<FrameStatusResult | null>(null);
  public readonly historySupported = signal<boolean>(false);
  public readonly selectedGhostNode = signal<DagCheckpointNode | null>(null);
  public readonly activeDiff = signal<DecodedDiff | null>(null);
  public readonly sessionLanes = signal<DagLaneView[]>([
    {
      id: 0,
      parent: 0,
      name: 'Root Run',
      forkR: 0n,
      endR: 0n,
      reason: ForkReason.Base,
      reasonBadge: '',
      actor: 'human',
      isLive: true,
      isPinned: true,
      nodes: [],
    },
  ]);
  public readonly activeLaneId = signal<number>(0);
  public readonly currentR = computed<bigint>(() => this.virtualTimeNs());
  private stepCounter = 0n;

  // Progressive Peripherals & Console / Activity Streams
  public readonly periphBlocks = signal<string[]>([]);
  public readonly selectedPeriphBlock = signal<string>('');
  public readonly selectedPeriphText = signal<string>('');
  public readonly fittedParts = signal<string[]>([]);
  public readonly activityLog = signal<ActivityLogEntry[]>([]);
  public readonly consoleEntries = signal<ConsoleEntry[]>([]);
  public readonly memoryEpoch = signal<number>(0);

  // Theme state ('dark' | 'light')
  public readonly currentTheme = signal<'dark' | 'light'>(
    typeof window !== 'undefined' && window.matchMedia && window.matchMedia('(prefers-color-scheme: light)').matches
      ? 'light'
      : 'dark'
  );

  // High-throughput LCD dirty rect stream
  public readonly lcdDirty$ = new Subject<DirtyRect>();

  constructor() {
    this.setTheme(this.currentTheme());
    void this.connect(this.serverUrl());
  }

  public toggleTheme(): void {
    const next = this.currentTheme() === 'dark' ? 'light' : 'dark';
    this.setTheme(next);
  }

  public setTheme(theme: 'dark' | 'light'): void {
    this.currentTheme.set(theme);
    if (typeof document !== 'undefined') {
      document.body.setAttribute('data-theme', theme);
      document.body.classList.toggle('theme-light', theme === 'light');
      document.body.classList.toggle('theme-dark', theme === 'dark');
    }
  }

  ngOnDestroy(): void {
    this.disconnect();
  }

  public async connect(url: string = this.serverUrl()): Promise<void> {
    if (this.client) {
      this.disconnect();
    }

    this.serverUrl.set(url);
    this.connectionState.set('connecting');
    this.errorMessage.set(null);

    const client = new RA8RpcClient({ timeoutMs: 5000 });
    this.client = client;

    client.on('error', (err: Error) => {
      this.errorMessage.set(err.message || 'Emulator RPC transport error');
    });

    client.on('close', () => {
      this.connectionState.set('disconnected');
      this.executionStatus.set('stopped');
      this.cpu0StateLabel.set('OFFLINE');
      this.cpu1StateLabel.set('OFFLINE');
      this.stopMetricsPoll();
    });

    client.on('lcd_dirty', (rect: DirtyRect) => {
      this.lcdDirty$.next(rect);
    });

    client.on('uart', (evt: UartEvent) => {
      const text = this.decoder.decode(evt.bytes);
      this.appendConsole(text, false, evt.core);
    });

    client.on('stop', (evt: Stopped) => {
      this.lastStop.set(evt);
      this.executionStatus.set('halted');
      this.cpu0StateLabel.set(evt.core === Core.Cpu0 ? 'HALTED' : 'SYNC HALT');
      if (this.cpu1Attached()) {
        this.cpu1StateLabel.set(evt.core === Core.Cpu1 ? 'HALTED' : 'SYNC HALT');
      }
      void this.refreshAllInspection('Halt @ 0x' + (evt.address >>> 0).toString(16).padStart(8, '0'), '');
    });

    client.on('trace', (evt: TraceEvent) => {
      this.handleTraceEvent(evt);
    });

    client.on('transport', (evt: TransportEvent) => {
      this.logActivity(
        evt.core,
        'transport',
        evt.finished ? 'Transport Completed' : 'Transport Slice',
        `epoch=${evt.epoch} reached=${evt.reachedNs}ns`
      );
      if (evt.finished) {
        void this.refreshAllInspection('Seek/Advance Complete', '');
      }
    });

    client.on('session', (evt: SessionEvent) => {
      this.handleSessionEvent(evt);
    });

    try {
      const hello = await client.connect(url);
      this.serverCaps.set(hello.caps);
      this.connectionState.set('connected');
      this.executionStatus.set('halted');
      this.errorMessage.set(null);

      // Subscribe CPU0 topics
      await client.subscribe(Core.Cpu0, Topic.Stop);
      await client.subscribe(Core.Cpu0, Topic.Uart);
      try {
        await client.subscribe(Core.Cpu0, Topic.LcdDirty, 60);
      } catch {
        // Headless board without GLCDC panel refuses lcd_dirty cleanly
      }
      await client.subscribe(Core.Cpu0, Topic.Session);
      try {
        await client.subscribe(Core.Cpu0, Topic.Trace);
      } catch {
        // Trace topic optional when firmware has no RTOS symbol hooks
      }
      try {
        await client.subscribe(Core.Cpu0, Topic.Transport);
      } catch {}

      // Probe companion core CPU1 (Cortex-M33)
      await this.probeCpu1();

      // Hydrate board profile, peripherals, dual-core inspection, telemetry, and DAG
      await this.refreshBoardParts();
      await this.refreshPeripheralsList();
      await this.refreshAllInspection('Initial Boot Halt', '');
      await this.refreshMetrics();
      await this.refreshBranches();

      this.startMetricsPoll();
    } catch {
      this.connectionState.set('error');
      this.errorMessage.set(`Offline — backend unreachable at ${url}`);
    }
  }

  public disconnect(): void {
    this.stopMetricsPoll();
    if (this.client) {
      try {
        this.client.disconnect();
      } catch {}
      this.client = null;
    }
    this.connectionState.set('disconnected');
    this.executionStatus.set('stopped');
    this.pacingRatio.set(null);
    this.lastVirtualNsSample = null;
    this.lastWallMsSample = null;
  }

  private async probeCpu1(): Promise<void> {
    if (!this.client) return;
    try {
      const regs = await this.client.readRegisters(Core.Cpu1);
      this.cpu1Attached.set(true);
      this.cpu1Registers.set(regs);
      this.cpu1Pc.set(regs['pc'] ?? 0);
      this.cpu1StateLabel.set('HALTED');
      await this.client.subscribe(Core.Cpu1, Topic.Stop);
      await this.client.subscribe(Core.Cpu1, Topic.Uart);
      await this.client.subscribe(Core.Cpu1, Topic.Session);
      try {
        await this.client.subscribe(Core.Cpu1, Topic.Trace);
      } catch {}
    } catch {
      this.cpu1Attached.set(false);
      this.cpu1StateLabel.set('CLOCK-GATED');
      if (this.inspectionMode() === 'cpu1') {
        this.inspectionMode.set('cpu0');
      }
    }
  }

  public setInspectionMode(mode: CoreInspectionMode): void {
    this.inspectionMode.set(mode);
    if (mode === 'cpu1' && this.cpu1Attached()) {
      this.activeCore.set(Core.Cpu1);
    } else if (mode === 'cpu0') {
      this.activeCore.set(Core.Cpu0);
    }
  }

  /* ------------------------------------------------------------------------ */
  /* Board-Wide Synchronized Execution & Time-Travel Controls                 */
  /* ------------------------------------------------------------------------ */

  public async run(): Promise<void> {
    if (!this.client || this.connectionState() !== 'connected') return;
    try {
      await this.client.run(Core.Cpu0, RunMode.Run);
      if (this.cpu1Attached()) {
        try { await this.client.run(Core.Cpu1, RunMode.Run); } catch {}
      }
      this.executionStatus.set('running');
      this.cpu0StateLabel.set('RUNNING');
      if (this.cpu1Attached()) {
        this.cpu1StateLabel.set('RUNNING');
      }
    } catch (err: any) {
      this.errorMessage.set(`Run failed: ${err.message}`);
    }
  }

  public async pause(): Promise<void> {
    if (!this.client || this.connectionState() !== 'connected') return;
    try {
      await this.client.pause(Core.Cpu0);
      if (this.cpu1Attached()) {
        try { await this.client.pause(Core.Cpu1); } catch {}
      }
      this.executionStatus.set('halted');
      this.cpu0StateLabel.set('HALTED');
      if (this.cpu1Attached()) {
        this.cpu1StateLabel.set('HALTED');
      }
      await this.refreshAllInspection('Paused', '');
    } catch (err: any) {
      this.errorMessage.set(`Pause failed: ${err.message}`);
    }
  }

  public async step(core: Core = Core.Cpu0): Promise<void> {
    if (!this.client || this.connectionState() !== 'connected') return;
    try {
      await this.client.step(core);
      this.stepCounter += 1n;
      this.executionStatus.set('halted');
      this.cpu0StateLabel.set('STEPPED');
      if (this.cpu1Attached()) {
        this.cpu1StateLabel.set(core === Core.Cpu1 ? 'STEPPED' : 'SYNC HALT');
      }
      await this.refreshAllInspection('Step', '');
    } catch (err: any) {
      this.errorMessage.set(`Step failed: ${err.message}`);
    }
  }

  public async reverseStep(): Promise<void> {
    if (!this.client || this.connectionState() !== 'connected') return;
    try {
      await this.client.reverseContinue(Core.Cpu0);
      this.executionStatus.set('halted');
      this.cpu0StateLabel.set('REWOUND');
      await this.refreshAllInspection('Reverse Continue', '');
      await this.refreshBranches();
    } catch {
      // Fallback: try seeking back 1 frame if transport/history is active
      try {
        await this.client.seek('-1f');
        await this.refreshAllInspection('Rewind -1f', '');
      } catch {
        this.logActivity(Core.Cpu0, 'transport', 'Rewind Unavailable', 'Start serve with --history-dir to enable full hardware rewind');
      }
    }
  }

  public async reset(): Promise<void> {
    if (this.client && this.connectionState() === 'connected') {
      try {
        await this.client.seek('0');
        await this.refreshAllInspection('Seek Origin (t=0)', '');
        return;
      } catch {
        // Hardware reset / seek(0) requires --history-dir or image reload
      }
    }
    this.appendConsole(
      'Session reset note: start ra8_emulator serve with --history-dir to seek to t=0, or reload ELF image.',
      true,
      Core.Cpu0
    );
  }

  public async setSpeed(milli: number): Promise<void> {
    this.speedMilli.set(milli);
    if (!this.client || this.connectionState() !== 'connected') return;
    try {
      await this.client.setSpeed(Core.Cpu0, BigInt(milli));
    } catch {}
  }

  /* ------------------------------------------------------------------------ */
  /* Dual-Core Inspection: Registers, Authoritative Disasm, Stack, Memory     */
  /* ------------------------------------------------------------------------ */

  public async refreshAllInspection(checkpointLabel?: string, badge = ''): Promise<void> {
    await Promise.all([
      this.refreshRegisters(),
      this.refreshDisassembly(Core.Cpu0),
      this.cpu1Attached() ? this.refreshDisassembly(Core.Cpu1) : Promise.resolve(),
      this.refreshBacktrace(),
      this.refreshStacks(),
      this.refreshBranches(),
    ]);
    this.memoryEpoch.update((n) => n + 1);
    if (checkpointLabel) {
      this.recordSessionCheckpoint(checkpointLabel, badge);
    }
  }

  public async refreshRegisters(): Promise<void> {
    if (!this.client || this.connectionState() !== 'connected') return;
    try {
      const r0 = await this.client.readRegisters(Core.Cpu0);
      this.cpu0PrevRegisters.set(this.cpu0Registers());
      this.cpu0Registers.set(r0);
      this.cpu0Pc.set(r0['pc'] ?? 0);
    } catch {}

    if (this.cpu1Attached()) {
      try {
        const r1 = await this.client.readRegisters(Core.Cpu1);
        this.cpu1PrevRegisters.set(this.cpu1Registers());
        this.cpu1Registers.set(r1);
        this.cpu1Pc.set(r1['pc'] ?? 0);
      } catch {}
    }
  }

  public async refreshDisassembly(
    core: Core = Core.Cpu0,
    address?: number,
    count = 28
  ): Promise<DisasmRow[]> {
    if (!this.client || this.connectionState() !== 'connected') return [];
    try {
      const reply = await this.client.disassemble(core, {
        address,
        count,
        usePc: address === undefined,
      });
      if (core === Core.Cpu0) {
        this.cpu0Pc.set(reply.pc);
        this.cpu0Disasm.set(reply.rows);
      } else {
        this.cpu1Pc.set(reply.pc);
        this.cpu1Disasm.set(reply.rows);
      }
      return reply.rows;
    } catch {
      return [];
    }
  }

  public async writeRegister(register: Register, value: number, core: Core = Core.Cpu0): Promise<boolean> {
    if (!this.client || this.connectionState() !== 'connected') return false;
    try {
      const ok = await this.client.writeRegister(core, register, value);
      if (ok) {
        this.recordInterventionFork(ForkReason.Writes, `Reg write @ CPU${core} = 0x${(value >>> 0).toString(16)}`);
        await this.refreshAllInspection('Reg Write', 'W');
      }
      return ok;
    } catch (err: any) {
      this.errorMessage.set(`Write register failed: ${err.message}`);
      return false;
    }
  }

  public async readMemory(address: number, length: number, core: Core = Core.Cpu0): Promise<Uint8Array | null> {
    if (!this.client || this.connectionState() !== 'connected') return null;
    try {
      return await this.client.readMemory(core, address, length);
    } catch {
      return null;
    }
  }

  public async writeMemory(address: number, bytes: Uint8Array, core: Core = Core.Cpu0): Promise<boolean> {
    if (!this.client || this.connectionState() !== 'connected') return false;
    try {
      const ok = await this.client.writeMemory(core, address, bytes);
      if (ok) {
        this.recordInterventionFork(ForkReason.Writes, `Mem write @ 0x${(address >>> 0).toString(16)}`);
        await this.refreshAllInspection(`Mem Write 0x${(address >>> 0).toString(16)}`, 'W');
      }
      return ok;
    } catch (err: any) {
      this.errorMessage.set(`Write memory failed: ${err.message}`);
      return false;
    }
  }

  public async toggleBreakpoint(address: number, core: Core = Core.Cpu0): Promise<boolean> {
    if (!this.client || this.connectionState() !== 'connected') return false;
    const signalMap = core === Core.Cpu1 ? this.cpu1Breakpoints : this.cpu0Breakpoints;
    const next = new Map(signalMap());
    const normalized = address & ~1;

    try {
      const existingId = next.get(normalized);
      if (existingId !== undefined) {
        await this.client.clearBreakpointById(core, existingId);
        next.delete(normalized);
      } else {
        const id = await this.client.setBreakpointId(core, normalized);
        next.set(normalized, id);
      }
      signalMap.set(next);
      return true;
    } catch (err: any) {
      this.errorMessage.set(`Breakpoint error: ${err.message}`);
      return false;
    }
  }

  public async refreshBacktrace(): Promise<void> {
    if (!this.client || this.connectionState() !== 'connected') return;
    try {
      this.cpu0Backtrace.set(await this.client.getBacktrace(Core.Cpu0));
    } catch {
      this.cpu0Backtrace.set(null);
    }
    if (this.cpu1Attached()) {
      try {
        this.cpu1Backtrace.set(await this.client.getBacktrace(Core.Cpu1));
      } catch {
        this.cpu1Backtrace.set(null);
      }
    }
  }

  public async refreshStacks(): Promise<void> {
    if (!this.client || this.connectionState() !== 'connected') return;
    try {
      this.cpu0Stack.set(await this.client.getStackReport(Core.Cpu0));
    } catch {}
    if (this.cpu1Attached()) {
      try {
        this.cpu1Stack.set(await this.client.getStackReport(Core.Cpu1));
      } catch {}
    }
  }

  public async refreshBoardParts(): Promise<void> {
    if (!this.client || this.connectionState() !== 'connected') return;
    try {
      const parts = await this.client.getBoardParts();
      this.boardParts.set(parts);
    } catch {}
  }

  /* ------------------------------------------------------------------------ */
  /* Progressive Peripheral Inspector (Tier 2 & Tier 3)                       */
  /* ------------------------------------------------------------------------ */

  public async refreshPeripheralsList(): Promise<void> {
    if (!this.client || this.connectionState() !== 'connected') return;
    try {
      const raw = await this.client.getPeriph(Core.Cpu0, '');
      const blocks = raw
        .split('\n')
        .map((line) => line.trim().split(/\s+/)[0] ?? '')
        .filter((name) => name.length > 0);
      this.periphBlocks.set(blocks);
      if (blocks.some((b) => b.toLowerCase().includes('npu') || b.toLowerCase().includes('ethos'))) {
        this.npuStateLabel.set('IDLE (ETHOS-U55)');
      }
      if (!this.selectedPeriphBlock() && blocks.length > 0) {
        const preferred = blocks.find((b) => /^(GPIO|SCI|GLCDC|GPT|ICU)/i.test(b)) ?? blocks[0]!;
        await this.selectPeriphBlock(preferred);
      }
    } catch {}

    try {
      const fitted = await this.client.getListParts(Core.Cpu0);
      this.fittedParts.set(fitted);
    } catch {}
  }

  public async selectPeriphBlock(block: string): Promise<void> {
    this.selectedPeriphBlock.set(block);
    if (!this.client || this.connectionState() !== 'connected' || !block) return;
    try {
      const dump = await this.client.getPeriph(Core.Cpu0, block, false);
      this.selectedPeriphText.set(dump);
    } catch {
      this.selectedPeriphText.set(`Unable to read peripheral block ${block}`);
    }
  }

  /* ------------------------------------------------------------------------ */
  /* Host Self-Profiling, Pacing Ratio, & Guest Telemetry                     */
  /* ------------------------------------------------------------------------ */

  public async refreshMetrics(): Promise<void> {
    if (!this.client || this.connectionState() !== 'connected') return;
    try {
      const [m, vns] = await Promise.all([
        this.client.getMetrics(),
        this.client.now(Core.Cpu0).catch(() => this.virtualTimeNs()),
      ]);
      this.metrics.set(m);
      this.virtualTimeNs.set(vns);

      const wallMs = performance.now();
      if (this.lastVirtualNsSample !== null && this.lastWallMsSample !== null) {
        const dVirtNs = Number(vns - this.lastVirtualNsSample);
        const dWallNs = (wallMs - this.lastWallMsSample) * 1_000_000;
        if (dWallNs > 0 && dVirtNs >= 0) {
          this.pacingRatio.set(dVirtNs / dWallNs);
        }
      }
      this.lastVirtualNsSample = vns;
      this.lastWallMsSample = wallMs;

      this.hostCpuHistory.update((arr) => [...arr.slice(-59), m.hostCpuPercent]);
      this.hostRssHistory.update((arr) => [...arr.slice(-59), m.hostRssMb]);
    } catch {}
  }

  /* ------------------------------------------------------------------------ */
  /* Time-Travel DAG, Fork Confirmation, Seek, & Ghost Diff                   */
  /* ------------------------------------------------------------------------ */

  public async refreshBranches(): Promise<void> {
    if (!this.client || this.connectionState() !== 'connected') return;
    try {
      const branches = await this.client.getBranches();
      this.backendBranches.set(branches);
      this.historySupported.set(true);
    } catch {
      this.historySupported.set(false);
    }

    try {
      const status = await this.client.getForkStatus();
      this.forkStatus.set(status);
    } catch {}

    try {
      const fs = await this.client.getFrameStatus();
      this.frameStatus.set(fs);
    } catch {}
  }

  public async seekTo(target: string): Promise<void> {
    if (!this.client || this.connectionState() !== 'connected' || !target.trim()) return;
    try {
      await this.client.seek(target.trim());
      await this.refreshAllInspection(`Seek ${target.trim()}`, '');
    } catch (err: any) {
      this.errorMessage.set(`Seek('${target}') unavailable: ${err.message}`);
    }
  }

  public async playHistory(dir: Direction, speedMilli = 1000n): Promise<void> {
    if (!this.client || this.connectionState() !== 'connected') return;
    try {
      await this.client.play(dir, speedMilli);
    } catch (err: any) {
      this.errorMessage.set(`History playback unavailable: ${err.message}`);
    }
  }

  public async switchBranch(branchId: number): Promise<void> {
    this.activeLaneId.set(branchId);
    if (!this.client || this.connectionState() !== 'connected') return;
    if (this.historySupported()) {
      try {
        await this.client.switchBranch(branchId);
        await this.refreshAllInspection(`Switch Branch #${branchId}`, '');
      } catch (err: any) {
        this.errorMessage.set(`Branch switch failed: ${err.message}`);
      }
    }
  }

  public async confirmPendingFork(): Promise<void> {
    if (!this.client || this.connectionState() !== 'connected') return;
    try {
      await this.client.confirmFork(true);
      await this.refreshBranches();
    } catch {}
  }

  public async cancelPendingFork(): Promise<void> {
    if (!this.client || this.connectionState() !== 'connected') return;
    try {
      await this.client.cancelFork();
      await this.refreshBranches();
    } catch {}
  }

  public async compareDiff(pointA: string, pointB: string): Promise<void> {
    if (!this.client || this.connectionState() !== 'connected') return;
    try {
      const diff = await this.client.getDiff(pointA, pointB);
      this.activeDiff.set(diff);
    } catch {
      this.activeDiff.set(null);
    }
  }

  public selectGhostCheckpoint(node: DagCheckpointNode | null): void {
    this.selectedGhostNode.set(node);
  }

  private recordSessionCheckpoint(label: string, badge: string): void {
    const r = this.virtualTimeNs() > 0n ? this.virtualTimeNs() : this.stepCounter;
    const node: DagCheckpointNode = {
      id: `cp-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`,
      branchId: this.activeLaneId(),
      r,
      pcCpu0: this.cpu0Pc(),
      pcCpu1: this.cpu1Pc(),
      label,
      badge,
      actor: this.actorMode(),
      timestamp: new Date().toLocaleTimeString(),
      registersCpu0: { ...this.cpu0Registers() },
      registersCpu1: { ...this.cpu1Registers() },
    };

    this.sessionLanes.update((lanes) =>
      lanes.map((lane) => {
        if (lane.id !== this.activeLaneId()) return lane;
        const nodes = [...lane.nodes.slice(-15), node];
        return { ...lane, endR: r, nodes };
      })
    );
  }

  private recordInterventionFork(reason: ForkReason, label: string): void {
    const ghost = this.selectedGhostNode();
    const badge = forkReasonBadge(reason);
    if (!ghost) return; // Linear mutation at HEAD stays on current lane unless inspecting an earlier checkpoint
    const nextId = this.sessionLanes().length;
    const forkR = ghost.r;
    const newLane: DagLaneView = {
      id: nextId,
      parent: ghost.branchId,
      name: `Branch #${nextId} (${label})`,
      forkR,
      endR: forkR,
      reason,
      reasonBadge: badge,
      actor: this.actorMode(),
      isLive: true,
      isPinned: false,
      nodes: [],
    };
    this.sessionLanes.update((lanes) =>
      lanes.map((l) => ({ ...l, isLive: false })).concat(newLane)
    );
    this.activeLaneId.set(nextId);
    this.selectedGhostNode.set(null);
  }

  /* ------------------------------------------------------------------------ */
  /* Hardware Inputs (Touch, Buttons, Console)                                */
  /* ------------------------------------------------------------------------ */

  public async sendTouch(kind: InputKind, x: number, y: number, toX = 0, toY = 0, durationNs = 0n): Promise<void> {
    if (!this.client || this.connectionState() !== 'connected') return;
    try {
      await this.client.sendInput({
        core: Core.Cpu0,
        atNs: 0n,
        kind,
        x,
        y,
        toX,
        toY,
        durationNs,
      });
      this.recordInterventionFork(ForkReason.Taps, `Touch (${x},${y})`);
      this.recordSessionCheckpoint(`Touch (${x},${y})`, 'T');
    } catch {}
  }

  public async sendButton(buttonIndex: number): Promise<void> {
    if (!this.client || this.connectionState() !== 'connected') return;
    try {
      await this.client.sendInput({
        core: Core.Cpu0,
        atNs: 0n,
        kind: InputKind.Button,
        button: buttonIndex,
      });
      const swName = this.boardParts()?.switchNames?.[buttonIndex] ?? `SW${buttonIndex + 1}`;
      this.recordInterventionFork(ForkReason.Buttons, swName);
      this.recordSessionCheckpoint(`Press ${swName}`, 'B');
    } catch {}
  }

  public async sendConsoleInput(text: string): Promise<void> {
    if (!this.client || this.connectionState() !== 'connected') return;
    const encoder = new TextEncoder();
    const bytes = encoder.encode(text.endsWith('\n') ? text : text + '\n');
    this.appendConsole(text, true, Core.Cpu0);
    try {
      await this.client.sendConsoleInput(Core.Cpu0, bytes);
      this.recordInterventionFork(ForkReason.Keystrokes, 'UART TX');
      this.recordSessionCheckpoint('UART Input', 'K');
    } catch (err: any) {
      this.errorMessage.set(`Console input error: ${err.message}`);
    }
  }

  public clearConsole(): void {
    this.consoleEntries.set([]);
  }

  /* ------------------------------------------------------------------------ */
  /* Event Stream Handlers                                                    */
  /* ------------------------------------------------------------------------ */

  private handleSessionEvent(evt: SessionEvent): void {
    if (evt.kind === EventKind.LedChanged) {
      const mask = evt.address;
      const leds: boolean[] = [];
      for (let i = 0; i < 8; i++) {
        leds.push((mask & (1 << i)) !== 0);
      }
      this.ledStates.set(leds);
      return;
    }

    const names: Record<number, { cat: ActivityLogEntry['category']; label: string }> = {
      [EventKind.Loaded]: { cat: 'session', label: 'Image Loaded' },
      [EventKind.RegisterWritten]: { cat: 'session', label: 'Register Written' },
      [EventKind.MemoryWritten]: { cat: 'bus', label: 'Memory Written' },
      [EventKind.BreakpointSet]: { cat: 'session', label: 'Breakpoint Set' },
      [EventKind.BreakpointCleared]: { cat: 'session', label: 'Breakpoint Cleared' },
      [EventKind.FaultSet]: { cat: 'fault', label: 'Fault Injected' },
      [EventKind.FaultCleared]: { cat: 'fault', label: 'Fault Cleared' },
      [EventKind.Plugged]: { cat: 'bus', label: 'Part Plugged' },
      [EventKind.Unplugged]: { cat: 'bus', label: 'Part Unplugged' },
      [EventKind.ModuleLoaded]: { cat: 'rtos', label: 'TXM Module Loaded' },
      [EventKind.ModuleFaulted]: { cat: 'fault', label: 'TXM Module Fault' },
    };
    const meta = names[evt.kind];
    if (meta) {
      this.logActivity(evt.core, meta.cat, meta.label, `0x${(evt.address >>> 0).toString(16).padStart(8, '0')}`);
    }
  }

  private handleTraceEvent(evt: TraceEvent): void {
    if (evt.kind === EventKind.RtosSwitch || evt.kind === EventKind.RtosIdle) {
      const name = evt.kind === EventKind.RtosIdle ? 'IDLE' : (evt.name || `Thread 0x${evt.thread.toString(16)}`);
      const key = `${evt.core}:${name}`;
      const prev = this.rtosSwitchMap.get(key) ?? { core: evt.core, thread: evt.thread, name, count: 0 };
      prev.count += 1;
      this.rtosSwitchMap.set(key, prev);

      let total = 0;
      for (const item of this.rtosSwitchMap.values()) total += item.count;
      const list: RtosTaskSummary[] = Array.from(this.rtosSwitchMap.entries())
        .map(([k, v]) => ({
          key: k,
          core: v.core,
          thread: v.thread,
          name: v.name,
          switches: v.count,
          sharePercent: total > 0 ? Math.round((v.count * 100) / total) : 0,
        }))
        .sort((a, b) => b.switches - a.switches)
        .slice(0, 6);
      this.rtosTasks.set(list);
    } else if (evt.kind === EventKind.IsrEnter) {
      this.logActivity(evt.core, 'rtos', `ISR #${evt.exception} Enter`, `t=${evt.virtualNs}ns`);
    }
  }

  private logActivity(
    core: Core,
    category: ActivityLogEntry['category'],
    label: string,
    detail: string
  ): void {
    const time = new Date().toLocaleTimeString();
    const id = this.nextLogId++;
    this.activityLog.update((entries) => [{ id, time, core, category, label, detail }, ...entries.slice(0, 79)]);
  }

  private appendConsole(text: string, isInput: boolean, core: Core): void {
    const time = new Date().toLocaleTimeString();
    this.consoleEntries.update((entries) => {
      const next = [...entries, { text, time, isInput, core }];
      if (next.length > 500) next.shift();
      return next;
    });
  }

  private startMetricsPoll(): void {
    this.stopMetricsPoll();
    this.metricsTimer = setInterval(() => {
      void this.refreshMetrics();
    }, 1000);
  }

  private stopMetricsPoll(): void {
    if (this.metricsTimer) {
      clearInterval(this.metricsTimer);
      this.metricsTimer = null;
    }
  }
}
