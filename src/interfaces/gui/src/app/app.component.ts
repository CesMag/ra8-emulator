import { Component, HostListener, inject, signal, computed, effect } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { ConnectionBarComponent } from './components/connection-bar/connection-bar.component';
import { VirtualBoardComponent } from './components/virtual-board/virtual-board.component';
import { DisassemblyViewComponent } from './components/disassembly-view/disassembly-view.component';
import { MemoryInspectorComponent } from './components/memory-inspector/memory-inspector.component';
import { PeripheralInspectorComponent } from './components/peripheral-inspector/peripheral-inspector.component';
import { RegisterInspectorComponent } from './components/register-inspector/register-inspector.component';
import { LocalsWatchComponent } from './components/locals-watch/locals-watch.component';
import { CallStackComponent } from './components/call-stack/call-stack.component';
import { MetricsPanelComponent } from './components/metrics-panel/metrics-panel.component';
import { UartTerminalComponent } from './components/uart-terminal/uart-terminal.component';
import { ExecutionDagComponent } from './components/execution-dag/execution-dag.component';
import { EmulatorService, CoreInspectionMode } from './services/emulator.service';
import { Core, StopReason } from 'ra8-rpc-client';

export type TopDeckTab = 'disasm' | 'memory' | 'periph';
export type BottomDeckTab = 'registers' | 'locals' | 'stack' | 'metrics';
export type DrawerTab = 'terminal' | 'dag';

@Component({
  selector: 'app-root',
  standalone: true,
  imports: [
    CommonModule,
    FormsModule,
    ConnectionBarComponent,
    VirtualBoardComponent,
    DisassemblyViewComponent,
    MemoryInspectorComponent,
    PeripheralInspectorComponent,
    RegisterInspectorComponent,
    LocalsWatchComponent,
    CallStackComponent,
    MetricsPanelComponent,
    UartTerminalComponent,
    ExecutionDagComponent,
  ],
  templateUrl: './app.component.html',
  styleUrls: ['./app.component.css']
})
export class AppComponent {
  public emu = inject(EmulatorService);
  public Core = Core;

  public topDeckTab = signal<TopDeckTab>('disasm');
  public bottomDeckTab = signal<BottomDeckTab>('registers');
  public drawerTab = signal<DrawerTab>('terminal');
  public drawerCollapsed = signal<boolean>(false);
  public dismissedHalt = signal<boolean>(false);
  public dismissedQuickstart = signal<boolean>(false);
  public isDraggingFile = signal<boolean>(false);
  public quickCopied = signal<boolean>(false);

  private dragDepth = 0;
  private lastDiagTick = 0;

  public isConnected = computed(() => this.emu.connectionState() === 'connected');
  public isRunning = computed(() => this.emu.executionStatus() === 'running');
  public cpu1Attached = this.emu.cpu1Attached;
  public inspectionMode = this.emu.inspectionMode;
  public speed = this.emu.speedMilli;
  public lastStopInfo = this.emu.lastStop;

  public activeStopCount = computed(
    () => this.emu.allBreakpoints().length + this.emu.watchpoints().length
  );

  public showQuickstartBanner = computed(
    () => !this.isConnected() && !this.dismissedQuickstart()
  );

  public showErrorBanner = computed(() => {
    const msg = this.emu.errorMessage();
    return !!msg && !msg.startsWith('Offline — backend unreachable');
  });

  public showHaltBanner = computed(() => {
    return !this.dismissedHalt() && this.lastStopInfo() !== null && !this.isRunning();
  });

  public haltSourceBadge = computed(() => {
    const s = this.lastStopInfo();
    if (!s) return '';
    const sl = s.core === Core.Cpu1 ? this.emu.cpu1SourceLine() : this.emu.cpu0SourceLine();
    if (!sl || !sl.found || !sl.path) return '';
    const base = sl.path.split(/[\\/]/).pop() ?? sl.path;
    return `${base}:${sl.line}`;
  });

  public canSkipBkpt = computed(() => {
    const s = this.lastStopInfo();
    return !!s && (s.reason === StopReason.Breakpoint || s.reason === StopReason.UnitBreak);
  });

  public lastStopReason = computed(() => {
    const s = this.lastStopInfo();
    if (!s) return '';
    const reasons = [
      'Stepped',
      'Breakpoint Hit',
      'Watchpoint Hit',
      'Halt Requested',
      'Unit Break',
      'Unit Watch',
      'Budget Reached',
      'Core Fault',
      'Replay Failed',
    ];
    return reasons[s.reason] || `Stop (${s.reason})`;
  });

  public quickServeCommand = computed(() => {
    const raw = this.emu.serverUrl().trim();
    const hostPort = raw.replace(/^wss?:\/\//i, '') || '127.0.0.1:4567';
    return `ra8_emulator serve <firmware.elf> --listen tcp:${hostPort}`;
  });

  constructor() {
    effect(() => {
      const open = this.emu.dagDrawerOpen();
      if (open) {
        this.drawerTab.set('dag');
        this.drawerCollapsed.set(false);
      }
    });

    effect(() => {
      const stop = this.lastStopInfo();
      if (stop) {
        this.dismissedHalt.set(false);
      }
    });

    effect(() => {
      const memJump = this.emu.requestedMemoryJump();
      if (memJump !== null) {
        this.topDeckTab.set('memory');
      }
    });

    effect(() => {
      const diagTick = this.emu.openDiagnosticsTick();
      if (diagTick > this.lastDiagTick) {
        this.lastDiagTick = diagTick;
        this.bottomDeckTab.set('metrics');
      }
    });
  }

  @HostListener('window:keydown', ['$event'])
  public onGlobalKeydown(event: KeyboardEvent): void {
    const target = event.target as HTMLElement | null;
    const inInput =
      !!target &&
      (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.isContentEditable);

    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'o') {
      event.preventDefault();
      this.emu.requestOpenLoadPopover();
      return;
    }

    if (inInput || !this.isConnected()) return;

    if (event.key === 'F5' && !event.ctrlKey && !event.metaKey) {
      event.preventDefault();
      if (this.isRunning()) {
        void this.emu.pause();
      } else {
        void this.emu.run();
      }
    } else if (event.key === 'F10') {
      event.preventDefault();
      if (!this.isRunning()) void this.emu.stepOver();
    } else if (event.key === 'F11' && event.shiftKey) {
      event.preventDefault();
      if (!this.isRunning()) void this.emu.stepOut();
    } else if (event.key === 'F11') {
      event.preventDefault();
      if (!this.isRunning()) void this.emu.step();
    }
  }

  @HostListener('window:dragenter', ['$event'])
  public onDragEnter(event: DragEvent): void {
    if (!event.dataTransfer?.types.includes('Files')) return;
    event.preventDefault();
    this.dragDepth += 1;
    this.isDraggingFile.set(true);
  }

  @HostListener('window:dragover', ['$event'])
  public onDragOver(event: DragEvent): void {
    if (!event.dataTransfer?.types.includes('Files')) return;
    event.preventDefault();
    if (event.dataTransfer) {
      event.dataTransfer.dropEffect = 'copy';
    }
    this.isDraggingFile.set(true);
  }

  @HostListener('window:dragleave', ['$event'])
  public onDragLeave(event: DragEvent): void {
    if (!event.dataTransfer?.types.includes('Files')) return;
    event.preventDefault();
    this.dragDepth = Math.max(0, this.dragDepth - 1);
    if (this.dragDepth === 0) {
      this.isDraggingFile.set(false);
    }
  }

  @HostListener('window:drop', ['$event'])
  public async onDrop(event: DragEvent): Promise<void> {
    if (!event.dataTransfer?.files?.length) {
      this.dragDepth = 0;
      this.isDraggingFile.set(false);
      return;
    }
    event.preventDefault();
    this.dragDepth = 0;
    this.isDraggingFile.set(false);

    const file = event.dataTransfer.files[0];
    if (!file) return;
    const buf = await file.arrayBuffer();
    const core =
      this.emu.inspectionMode() === 'cpu1' && this.emu.cpu1Attached() ? Core.Cpu1 : Core.Cpu0;
    await this.emu.loadElfFile(file.name, new Uint8Array(buf), core, {
      breakAtMainAndRun: true,
    });
  }

  public copyQuickCommand(): void {
    void navigator.clipboard?.writeText(this.quickServeCommand());
    this.quickCopied.set(true);
    setTimeout(() => this.quickCopied.set(false), 1800);
  }

  public retryQuickConnect(): void {
    void this.emu.connect(this.emu.serverUrl());
  }

  public openLoadElf(): void {
    this.emu.requestOpenLoadPopover();
  }

  public dismissError(): void {
    this.emu.errorMessage.set(null);
  }

  public continueFromHalt(): void {
    void this.emu.run();
  }

  public skipHaltBkpt(): void {
    const s = this.lastStopInfo();
    void this.emu.skipBkpt(s ? s.core : Core.Cpu0);
  }

  public setTopTab(tab: TopDeckTab): void {
    this.topDeckTab.set(tab);
  }

  public setBottomTab(tab: BottomDeckTab): void {
    this.bottomDeckTab.set(tab);
  }

  public setDrawerTab(tab: DrawerTab): void {
    this.drawerTab.set(tab);
    if (this.drawerCollapsed()) {
      this.drawerCollapsed.set(false);
    }
    if (tab === 'dag') {
      this.emu.dagDrawerOpen.set(true);
    }
  }

  public toggleDrawerCollapse(): void {
    const next = !this.drawerCollapsed();
    this.drawerCollapsed.set(next);
    if (next && this.drawerTab() === 'dag') {
      this.emu.dagDrawerOpen.set(false);
    }
  }

  public setMode(mode: CoreInspectionMode): void {
    this.emu.setInspectionMode(mode);
  }

  public onSpeedChange(milli: number): void {
    void this.emu.setSpeed(milli);
  }

  public dismissBanner(): void {
    this.dismissedHalt.set(true);
  }

  public toHex8(val: number): string {
    return (val >>> 0).toString(16).padStart(8, '0');
  }
}
