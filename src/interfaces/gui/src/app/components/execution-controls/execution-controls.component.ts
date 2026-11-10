import { Component, inject, computed } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { EmulatorService, CoreInspectionMode } from '../../services/emulator.service';
import { Core } from 'ra8-rpc-client';

@Component({
  selector: 'app-execution-controls',
  standalone: true,
  imports: [CommonModule, FormsModule],
  template: `
    <div class="exec-bar-card" [class.disconnected]="!isConnected()">
      <div class="exec-row">
        <!-- Global Board-Session Execution Controls -->
        <div class="transport-group">
          <button
            type="button"
            class="ctrl-btn run"
            [disabled]="!isConnected() || isRunning()"
            (click)="run()"
            title="Run Board Session"
          >
            ▶ Run
          </button>

          <button
            type="button"
            class="ctrl-btn pause"
            [disabled]="!isConnected() || !isRunning()"
            (click)="pause()"
            title="Pause Board Session"
          >
            ⏸ Pause
          </button>

          <button
            type="button"
            class="ctrl-btn"
            [disabled]="!isConnected() || isRunning()"
            (click)="stepCpu0()"
            title="Single-Step CPU0 (Cortex-M85)"
          >
            ⏭ Step M85
          </button>

          <button
            *ngIf="cpu1Attached()"
            type="button"
            class="ctrl-btn"
            [disabled]="!isConnected() || isRunning()"
            (click)="stepCpu1()"
            title="Single-Step CPU1 (Cortex-M33)"
          >
            ⏭ Step M33
          </button>

          <button
            type="button"
            class="ctrl-btn rewind"
            [disabled]="!isConnected() || isRunning()"
            (click)="reverseStep()"
            title="Reverse-Continue / Rewind History"
          >
            ⏮ Rewind
          </button>

          <button
            type="button"
            class="ctrl-btn"
            [disabled]="!isConnected()"
            (click)="reset()"
            title="Seek Session Origin (t=0)"
          >
            ↺ Origin
          </button>
        </div>

        <div class="v-divider"></div>

        <!-- Simultaneous Multi-Core & NPU Silicon Concurrency Indicators -->
        <div class="silicon-strip">
          <div class="core-chip m85" [class.halted-hit]="hitCore() === Core.Cpu0">
            <span class="core-dot" [class.live]="isRunning()"></span>
            <span class="core-arch">CPU0 • M85 &#64; 480MHz</span>
            <span class="core-pc" *ngIf="isConnected()">0x{{ toHex8(emu.cpu0Pc()) }}</span>
            <span class="core-state">{{ emu.cpu0StateLabel() }}</span>
          </div>

          <div
            class="core-chip m33"
            [class.unattached]="!cpu1Attached()"
            [class.halted-hit]="hitCore() === Core.Cpu1"
          >
            <span class="core-dot" [class.live]="isRunning() && cpu1Attached()"></span>
            <span class="core-arch">CPU1 • M33 &#64; 240MHz</span>
            <span class="core-pc" *ngIf="isConnected() && cpu1Attached()">0x{{ toHex8(emu.cpu1Pc()) }}</span>
            <span class="core-state">{{ emu.cpu1StateLabel() }}</span>
          </div>

          <div class="core-chip npu">
            <span class="core-arch">Ethos-U55 NPU</span>
            <span class="core-state">{{ emu.npuStateLabel() }}</span>
          </div>
        </div>

        <div class="v-divider"></div>

        <!-- Pacing & Dual-Core Layout Mode -->
        <div class="right-controls">
          <div class="pacing-box" title="Throttle virtual slice pacing (0 = maximum unthrottled host speed)">
            <span class="meta-label">Pacing</span>
            <input
              type="range"
              min="0"
              max="500"
              step="10"
              [ngModel]="speed()"
              (ngModelChange)="onSpeedChange($event)"
              [disabled]="!isConnected()"
              class="pacing-slider"
            />
            <span class="pacing-val">{{ speed() === 0 ? 'Max' : speed() + 'ms' }}</span>
          </div>

          <div class="layout-segmented" title="Synchronized Dual-Core Split View vs Single-Core Focus">
            <button
              type="button"
              class="seg-btn"
              [class.active]="mode() === 'split'"
              (click)="setMode('split')"
            >
              Split M85 | M33
            </button>
            <button
              type="button"
              class="seg-btn"
              [class.active]="mode() === 'cpu0'"
              (click)="setMode('cpu0')"
            >
              M85
            </button>
            <button
              type="button"
              class="seg-btn"
              [class.active]="mode() === 'cpu1'"
              [disabled]="!cpu1Attached()"
              (click)="setMode('cpu1')"
            >
              M33
            </button>
          </div>
        </div>
      </div>

      <!-- Breakpoint / Halt Event Banner -->
      <div *ngIf="lastStopInfo()" class="halt-strip">
        <span class="halt-tag">Halt Triggered</span>
        <span class="halt-core">{{ lastStopInfo()!.core === Core.Cpu0 ? 'CPU0 (Cortex-M85)' : 'CPU1 (Cortex-M33)' }}</span>
        <span class="halt-reason">{{ lastStopReason() }}</span>
        <span class="halt-pc">PC = 0x{{ toHex8(lastStopInfo()!.address) }}</span>
        <span *ngIf="lastStopDetail()" class="halt-detail">Detail: {{ lastStopDetail() }}</span>
      </div>
    </div>
  `,
  styles: [`
    .exec-bar-card {
      background: linear-gradient(180deg, rgba(15, 23, 42, 0.86), rgba(8, 12, 22, 0.92));
      border: 1px solid rgba(255, 255, 255, 0.08);
      box-shadow: inset 0 1px 0 0 rgba(255, 255, 255, 0.06);
      border-radius: 10px;
      overflow: hidden;
      transition: opacity 0.2s ease;
    }

    .exec-bar-card.disconnected .transport-group,
    .exec-bar-card.disconnected .pacing-box {
      opacity: 0.35;
    }

    .exec-row {
      display: flex;
      align-items: center;
      gap: 12px;
      padding: 7px 12px;
      flex-wrap: wrap;
    }

    .transport-group {
      display: flex;
      align-items: center;
      gap: 6px;
      flex-wrap: wrap;
    }

    .ctrl-btn {
      background: rgba(30, 41, 59, 0.85);
      color: #e2e8f0;
      border: 1px solid rgba(255, 255, 255, 0.1);
      border-radius: 6px;
      padding: 4px 10px;
      font-size: 0.73rem;
      font-weight: 600;
      cursor: pointer;
      transition: all 0.12s ease;
      display: inline-flex;
      align-items: center;
      gap: 4px;
    }
    .ctrl-btn:hover:not(:disabled) {
      background: rgba(51, 65, 85, 0.95);
      border-color: rgba(255, 255, 255, 0.2);
    }
    .ctrl-btn:disabled {
      cursor: not-allowed;
      opacity: 0.45;
    }

    .ctrl-btn.run {
      background: rgba(21, 128, 61, 0.85);
      border-color: rgba(34, 197, 94, 0.4);
      color: #f0fdf4;
    }
    .ctrl-btn.run:hover:not(:disabled) { background: #16a34a; }

    .ctrl-btn.pause {
      background: rgba(180, 83, 9, 0.85);
      border-color: rgba(245, 158, 11, 0.4);
      color: #fffbeb;
    }
    .ctrl-btn.pause:hover:not(:disabled) { background: #d97706; }

    .ctrl-btn.rewind {
      border-color: rgba(56, 189, 248, 0.3);
      color: #bae6fd;
    }

    .v-divider {
      width: 1px;
      height: 22px;
      background: rgba(255, 255, 255, 0.08);
    }

    .silicon-strip {
      display: flex;
      align-items: center;
      gap: 8px;
      flex-wrap: wrap;
      flex: 1;
    }

    .core-chip {
      display: inline-flex;
      align-items: center;
      gap: 7px;
      padding: 3px 9px;
      border-radius: 6px;
      background: rgba(9, 13, 22, 0.78);
      border: 1px solid rgba(255, 255, 255, 0.08);
      font-size: 0.69rem;
    }
    .core-chip.m85 { border-left: 2px solid #38bdf8; }
    .core-chip.m33 { border-left: 2px solid #a855f7; }
    .core-chip.npu { border-left: 2px solid #10b981; }
    .core-chip.unattached { opacity: 0.65; }
    .core-chip.halted-hit {
      border-color: rgba(250, 204, 21, 0.55);
      box-shadow: 0 0 10px rgba(250, 204, 21, 0.15);
    }

    .core-dot {
      width: 6px;
      height: 6px;
      border-radius: 50%;
      background: #64748b;
    }
    .core-dot.live {
      background: #22c55e;
      box-shadow: 0 0 6px #22c55e;
    }

    .core-arch {
      font-weight: 600;
      color: #e2e8f0;
    }

    .core-pc {
      font-family: "JetBrains Mono", monospace;
      color: #38bdf8;
      font-size: 0.67rem;
    }

    .core-state {
      font-family: "JetBrains Mono", monospace;
      font-size: 0.64rem;
      color: #94a3b8;
      background: rgba(30, 41, 59, 0.65);
      padding: 1px 5px;
      border-radius: 4px;
    }

    .right-controls {
      display: flex;
      align-items: center;
      gap: 10px;
      margin-left: auto;
      flex-wrap: wrap;
    }

    .pacing-box {
      display: flex;
      align-items: center;
      gap: 6px;
    }

    .meta-label {
      font-size: 0.7rem;
      color: #94a3b8;
      font-weight: 500;
    }

    .pacing-slider {
      width: 72px;
      accent-color: #38bdf8;
      cursor: pointer;
    }
    .pacing-slider:disabled { cursor: not-allowed; }

    .pacing-val {
      font-family: "JetBrains Mono", monospace;
      font-size: 0.68rem;
      color: #cbd5e1;
      min-width: 34px;
    }

    .layout-segmented {
      display: inline-flex;
      background: #090d16;
      border: 1px solid rgba(255, 255, 255, 0.1);
      border-radius: 6px;
      overflow: hidden;
    }

    .seg-btn {
      background: transparent;
      border: none;
      color: #94a3b8;
      font-size: 0.69rem;
      font-weight: 600;
      padding: 4px 8px;
      cursor: pointer;
      transition: all 0.12s;
    }
    .seg-btn:hover:not(:disabled) { color: #f8fafc; }
    .seg-btn.active {
      background: rgba(2, 132, 199, 0.3);
      color: #38bdf8;
    }
    .seg-btn:disabled {
      opacity: 0.35;
      cursor: not-allowed;
    }

    .halt-strip {
      display: flex;
      align-items: center;
      gap: 12px;
      padding: 4px 12px;
      background: rgba(245, 158, 11, 0.08);
      border-top: 1px solid rgba(245, 158, 11, 0.22);
      font-family: "JetBrains Mono", monospace;
      font-size: 0.69rem;
    }

    .halt-tag {
      color: #fbbf24;
      font-weight: 700;
    }
    .halt-core { color: #e2e8f0; }
    .halt-reason { color: #fde68a; }
    .halt-pc { color: #38bdf8; }
    .halt-detail { color: #94a3b8; }
  `]
})
export class ExecutionControlsComponent {
  public emu = inject(EmulatorService);
  public Core = Core;

  public isConnected = computed(() => this.emu.connectionState() === 'connected');
  public isRunning = computed(() => this.emu.executionStatus() === 'running');
  public cpu1Attached = this.emu.cpu1Attached;
  public speed = this.emu.speedMilli;
  public mode = this.emu.inspectionMode;
  public lastStopInfo = this.emu.lastStop;

  public hitCore = computed(() => {
    if (!this.isConnected() || this.isRunning()) return null;
    return this.lastStopInfo()?.core ?? null;
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

  public lastStopDetail = computed(() => {
    const s = this.lastStopInfo();
    return s && s.detail !== 0 ? `0x${s.detail.toString(16)}` : null;
  });

  public setMode(mode: CoreInspectionMode): void {
    this.emu.setInspectionMode(mode);
  }

  public run(): void {
    void this.emu.run();
  }

  public pause(): void {
    void this.emu.pause();
  }

  public stepCpu0(): void {
    void this.emu.step(Core.Cpu0);
  }

  public stepCpu1(): void {
    void this.emu.step(Core.Cpu1);
  }

  public reverseStep(): void {
    void this.emu.reverseStep();
  }

  public reset(): void {
    void this.emu.reset();
  }

  public onSpeedChange(milli: number): void {
    void this.emu.setSpeed(milli);
  }

  public toHex8(val: number): string {
    return (val >>> 0).toString(16).padStart(8, '0');
  }
}
