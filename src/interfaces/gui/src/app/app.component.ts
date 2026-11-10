import { Component, inject, signal, computed, effect } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { ConnectionBarComponent } from './components/connection-bar/connection-bar.component';
import { VirtualBoardComponent } from './components/virtual-board/virtual-board.component';
import { DisassemblyViewComponent } from './components/disassembly-view/disassembly-view.component';
import { MemoryInspectorComponent } from './components/memory-inspector/memory-inspector.component';
import { PeripheralInspectorComponent } from './components/peripheral-inspector/peripheral-inspector.component';
import { RegisterInspectorComponent } from './components/register-inspector/register-inspector.component';
import { CallStackComponent } from './components/call-stack/call-stack.component';
import { MetricsPanelComponent } from './components/metrics-panel/metrics-panel.component';
import { UartTerminalComponent } from './components/uart-terminal/uart-terminal.component';
import { ExecutionDagComponent } from './components/execution-dag/execution-dag.component';
import { EmulatorService, CoreInspectionMode } from './services/emulator.service';
import { Core } from 'ra8-rpc-client';

export type TopDeckTab = 'disasm' | 'memory' | 'periph';
export type BottomDeckTab = 'registers' | 'stack' | 'metrics';
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

  public isConnected = computed(() => this.emu.connectionState() === 'connected');
  public isRunning = computed(() => this.emu.executionStatus() === 'running');
  public cpu1Attached = this.emu.cpu1Attached;
  public inspectionMode = this.emu.inspectionMode;
  public speed = this.emu.speedMilli;
  public lastStopInfo = this.emu.lastStop;

  public showHaltBanner = computed(() => {
    return !this.dismissedHalt() && this.lastStopInfo() !== null && !this.isRunning();
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

  constructor() {
    // When DAG drawer is toggled from ConnectionBar, sync drawer state
    effect(() => {
      const open = this.emu.dagDrawerOpen();
      if (open) {
        this.drawerTab.set('dag');
        this.drawerCollapsed.set(false);
      }
    });

    // Reset dismissed state on new halt
    effect(() => {
      const stop = this.lastStopInfo();
      if (stop) {
        this.dismissedHalt.set(false);
      }
    });
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
