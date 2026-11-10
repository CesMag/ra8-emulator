import { Injectable, signal, computed, OnDestroy } from '@angular/core';
import { Subject, BehaviorSubject } from 'rxjs';
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
  MetricsReport,
  BoardParts,
  Backtrace,
  EventKind,
} from 'ra8-rpc-client';

export type ConnectionState = 'disconnected' | 'connecting' | 'connected' | 'error';
export type ExecutionStatus = 'stopped' | 'running' | 'halted';

export interface ConsoleEntry {
  text: string;
  time: string;
  isInput: boolean;
}

@Injectable({
  providedIn: 'root'
})
export class EmulatorService implements OnDestroy {
  private client: RA8RpcClient | null = null;
  private metricsTimer: any = null;
  private decoder = new TextDecoder();

  // Signals for reactive UI state
  public readonly connectionState = signal<ConnectionState>('disconnected');
  public readonly executionStatus = signal<ExecutionStatus>('stopped');
  public readonly activeCore = signal<Core>(Core.Cpu0);
  public readonly serverUrl = signal<string>('ws://127.0.0.1:4567');
  public readonly errorMessage = signal<string | null>(null);
  public readonly lastStop = signal<Stopped | null>(null);
  public readonly metrics = signal<MetricsReport | null>(null);
  public readonly boardParts = signal<BoardParts | null>(null);
  public readonly ledStates = signal<boolean[]>([false, false, false, false]);
  public readonly speedMilli = signal<number>(0);
  public readonly registers = signal<Record<string, number>>({});
  public readonly previousRegisters = signal<Record<string, number>>({});
  public readonly backtrace = signal<Backtrace | null>(null);
  public readonly breakpoints = signal<Set<number>>(new Set<number>());
  public readonly consoleEntries = signal<ConsoleEntry[]>([]);

  // Observables for high-throughput streaming
  public readonly lcdDirty$ = new Subject<DirtyRect>();

  constructor() {
    // Attempt auto-connect to default endpoint
    this.connect(this.serverUrl());
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
      console.warn('RPC Client Error:', err);
      this.errorMessage.set(err.message || 'Emulator connection error');
    });

    client.on('close', ({ code, reason }) => {
      console.info(`RPC Connection closed (${code}): ${reason}`);
      this.connectionState.set('disconnected');
      this.stopMetricsPoll();
    });

    client.on('lcd_dirty', (rect: DirtyRect) => {
      this.lcdDirty$.next(rect);
    });

    client.on('uart', (evt: UartEvent) => {
      const text = this.decoder.decode(evt.bytes);
      this.appendConsole(text, false);
    });

    client.on('stop', (evt: Stopped) => {
      this.lastStop.set(evt);
      this.executionStatus.set('halted');
      void this.refreshRegisters();
      void this.refreshBacktrace();
    });

    client.on('session', (evt: SessionEvent) => {
      if (evt.kind === EventKind.LedChanged) {
        // address contains LED bits
        const mask = evt.address;
        const leds = [
          (mask & 1) !== 0,
          (mask & 2) !== 0,
          (mask & 4) !== 0,
          (mask & 8) !== 0
        ];
        this.ledStates.set(leds);
      }
    });

    try {
      await client.connect(url);
      this.connectionState.set('connected');
      this.errorMessage.set(null);

      // Subscriptions
      const core = this.activeCore();
      await client.subscribe(core, Topic.Stop);
      await client.subscribe(core, Topic.Uart);
      await client.subscribe(core, Topic.LcdDirty, 60);
      await client.subscribe(core, Topic.Session);

      // Initial state fetch
      await this.refreshBoardParts();
      await this.refreshRegisters();
      await this.refreshBacktrace();
      await this.refreshMetrics();

      this.startMetricsPoll();
    } catch (err: any) {
      console.error('Failed to connect to emulator:', err);
      this.connectionState.set('error');
      this.errorMessage.set(
        `Could not connect to ${url}. Make sure ra8_emulator is running with 'serve --listen tcp:127.0.0.1:4567'.`
      );
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
  }

  public async switchCore(core: Core): Promise<void> {
    if (this.activeCore() === core) return;
    this.activeCore.set(core);

    if (this.client && this.connectionState() === 'connected') {
      try {
        await this.client.subscribe(core, Topic.Stop);
        await this.client.subscribe(core, Topic.Uart);
        await this.client.subscribe(core, Topic.Session);
      } catch (err) {
        console.warn(`Could not subscribe to core ${core}:`, err);
      }
      await this.refreshRegisters();
      await this.refreshBacktrace();
    }
  }

  public async run(): Promise<void> {
    if (!this.client || this.connectionState() !== 'connected') return;
    try {
      await this.client.run(this.activeCore(), RunMode.Run);
      this.executionStatus.set('running');
    } catch (err: any) {
      this.errorMessage.set(`Run error: ${err.message}`);
    }
  }

  public async pause(): Promise<void> {
    if (!this.client || this.connectionState() !== 'connected') return;
    try {
      await this.client.pause(this.activeCore());
      this.executionStatus.set('halted');
      await this.refreshRegisters();
      await this.refreshBacktrace();
    } catch (err: any) {
      this.errorMessage.set(`Pause error: ${err.message}`);
    }
  }

  public async step(): Promise<void> {
    if (!this.client || this.connectionState() !== 'connected') return;
    try {
      await this.client.step(this.activeCore());
      this.executionStatus.set('halted');
      await this.refreshRegisters();
      await this.refreshBacktrace();
    } catch (err: any) {
      this.errorMessage.set(`Step error: ${err.message}`);
    }
  }

  /**
   * Reset the emulator.
   * Note per ADR 0010 & Developer Handoff: The backend Session RPC wire protocol
   * does not expose a hardware reset method (no-op in native GUI menu as well).
   */
  public async reset(): Promise<void> {
    this.appendConsole(
      '[SYSTEM]: Note: Machine reset opcode is not exposed by current Session RPC wire protocol. To restart execution, pause, re-load the binary, or step from reset vector.',
      true
    );
  }

  public async setSpeed(milli: number): Promise<void> {
    this.speedMilli.set(milli);
    if (!this.client || this.connectionState() !== 'connected') return;
    try {
      await this.client.setSpeed(this.activeCore(), BigInt(milli));
    } catch (err) {
      console.warn('SetSpeed error:', err);
    }
  }

  public async refreshRegisters(): Promise<void> {
    if (!this.client || this.connectionState() !== 'connected') return;
    try {
      const current = await this.client.readRegisters(this.activeCore());
      this.previousRegisters.set(this.registers());
      this.registers.set(current);
    } catch (err) {
      // Ignored if core running or not halted
    }
  }

  public async writeRegister(register: Register, value: number): Promise<boolean> {
    if (!this.client || this.connectionState() !== 'connected') return false;
    try {
      const ok = await this.client.writeRegister(this.activeCore(), register, value);
      if (ok) {
        await this.refreshRegisters();
      }
      return ok;
    } catch (err: any) {
      this.errorMessage.set(`Write register error: ${err.message}`);
      return false;
    }
  }

  public async readMemory(address: number, length: number): Promise<Uint8Array | null> {
    if (!this.client || this.connectionState() !== 'connected') return null;
    try {
      return await this.client.readMemory(this.activeCore(), address, length);
    } catch (err) {
      return null;
    }
  }

  public async writeMemory(address: number, bytes: Uint8Array): Promise<boolean> {
    if (!this.client || this.connectionState() !== 'connected') return false;
    try {
      return await this.client.writeMemory(this.activeCore(), address, bytes);
    } catch (err: any) {
      this.errorMessage.set(`Write memory error: ${err.message}`);
      return false;
    }
  }

  public async toggleBreakpoint(address: number): Promise<boolean> {
    if (!this.client || this.connectionState() !== 'connected') return false;
    const bps = new Set(this.breakpoints());
    const isSet = bps.has(address);

    try {
      if (isSet) {
        await this.client.clearBreakpoint(this.activeCore(), address);
        bps.delete(address);
      } else {
        await this.client.setBreakpoint(this.activeCore(), address);
        bps.add(address);
      }
      this.breakpoints.set(bps);
      return true;
    } catch (err: any) {
      this.errorMessage.set(`Breakpoint error: ${err.message}`);
      return false;
    }
  }

  public async refreshBacktrace(): Promise<void> {
    if (!this.client || this.connectionState() !== 'connected') return;
    try {
      const bt = await this.client.getBacktrace(this.activeCore());
      this.backtrace.set(bt);
    } catch {
      this.backtrace.set(null);
    }
  }

  public async refreshBoardParts(): Promise<void> {
    if (!this.client || this.connectionState() !== 'connected') return;
    try {
      const parts = await this.client.getBoardParts();
      this.boardParts.set(parts);
    } catch {}
  }

  public async refreshMetrics(): Promise<void> {
    if (!this.client || this.connectionState() !== 'connected') return;
    try {
      const m = await this.client.getMetrics();
      this.metrics.set(m);
    } catch {}
  }

  public async sendTouch(kind: InputKind, x: number, y: number, toX = 0, toY = 0, durationNs = 0n): Promise<void> {
    if (!this.client || this.connectionState() !== 'connected') return;
    try {
      await this.client.sendInput({
        core: this.activeCore(),
        atNs: 0n,
        kind,
        x,
        y,
        toX,
        toY,
        durationNs
      });
    } catch (err) {
      console.warn('Touch input failed:', err);
    }
  }

  public async sendButton(buttonIndex: number): Promise<void> {
    if (!this.client || this.connectionState() !== 'connected') return;
    try {
      await this.client.sendInput({
        core: this.activeCore(),
        atNs: 0n,
        kind: InputKind.Button,
        button: buttonIndex
      });
    } catch (err) {
      console.warn('Button input failed:', err);
    }
  }

  public async sendConsoleInput(text: string): Promise<void> {
    if (!this.client || this.connectionState() !== 'connected') return;
    const encoder = new TextEncoder();
    const bytes = encoder.encode(text.endsWith('\n') ? text : text + '\n');
    this.appendConsole(text, true);
    try {
      await this.client.sendConsoleInput(this.activeCore(), bytes);
    } catch (err: any) {
      this.errorMessage.set(`Console input error: ${err.message}`);
    }
  }

  public clearConsole(): void {
    this.consoleEntries.set([]);
  }

  private appendConsole(text: string, isInput: boolean): void {
    const time = new Date().toLocaleTimeString();
    this.consoleEntries.update((entries) => {
      const next = [...entries, { text, time, isInput }];
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
