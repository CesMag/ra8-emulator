import { Component, inject, computed } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { EmulatorService } from '../../services/emulator.service';
import { Core, StopReason } from 'ra8-rpc-client';

@Component({
  selector: 'app-execution-controls',
  standalone: true,
  imports: [CommonModule, FormsModule],
  template: `
    <div class="controls-card">
      <div class="controls-toolbar">
        <!-- Target Core Selector -->
        <div class="core-selector">
          <span class="label">CORE:</span>
          <div class="btn-group">
            <button
              type="button"
              class="core-btn"
              [class.active]="activeCore() === Core.Cpu0"
              (click)="selectCore(Core.Cpu0)"
            >
              CPU0 (M85)
            </button>
            <button
              type="button"
              class="core-btn"
              [class.active]="activeCore() === Core.Cpu1"
              (click)="selectCore(Core.Cpu1)"
            >
              CPU1 (M33)
            </button>
          </div>
        </div>

        <div class="separator"></div>

        <!-- Run / Pause / Step / Reset Actions -->
        <div class="exec-actions">
          <button
            type="button"
            class="action-btn run-btn"
            [disabled]="!isConnected() || isRunning()"
            (click)="run()"
            title="Resume Execution (F5)"
          >
            ▶ Run
          </button>

          <button
            type="button"
            class="action-btn pause-btn"
            [disabled]="!isConnected() || !isRunning()"
            (click)="pause()"
            title="Pause Execution"
          >
            ⏸ Pause
          </button>

          <button
            type="button"
            class="action-btn step-btn"
            [disabled]="!isConnected() || isRunning()"
            (click)="step()"
            title="Step Instruction (F10)"
          >
            ⏭ Step
          </button>

          <button
            type="button"
            class="action-btn reset-btn"
            [disabled]="!isConnected()"
            (click)="reset()"
            title="Machine Reset Note"
          >
            🔄 Reset
          </button>
        </div>

        <div class="separator"></div>

        <!-- Emulation Speed Slider -->
        <div class="speed-control">
          <span class="label">PACING:</span>
          <input
            type="range"
            min="0"
            max="500"
            step="10"
            [ngModel]="speed()"
            (ngModelChange)="onSpeedChange($event)"
            [disabled]="!isConnected()"
            class="speed-slider"
          />
          <span class="speed-val">{{ speed() === 0 ? 'Max (0ms)' : speed() + 'ms' }}</span>
        </div>

        <!-- Status Indicator -->
        <div class="status-indicator" [ngClass]="statusClass()">
          <span class="status-dot"></span>
          <span class="status-text">{{ statusText() }}</span>
        </div>
      </div>

      <!-- Halt Notice Banner (when stopped) -->
      <div *ngIf="lastStopInfo()" class="stop-banner">
        <span class="stop-reason">Halted: {{ lastStopReason() }}</span>
        <span class="stop-pc">PC = 0x{{ lastStopPc() }}</span>
        <span *ngIf="lastStopDetail()" class="stop-detail">Detail: {{ lastStopDetail() }}</span>
      </div>
    </div>
  `,
  styles: [`
    .controls-card {
      background: var(--bg-secondary);
      border: 1px solid var(--border-color);
      border-radius: 8px;
      overflow: hidden;
    }

    .controls-toolbar {
      display: flex;
      align-items: center;
      gap: 12px;
      padding: 8px 12px;
      flex-wrap: wrap;
    }

    .separator {
      width: 1px;
      height: 24px;
      background: var(--border-color);
    }

    .label {
      font-size: 0.7rem;
      font-weight: 700;
      color: var(--text-secondary);
      margin-right: 4px;
    }

    .core-selector {
      display: flex;
      align-items: center;
    }

    .btn-group {
      display: flex;
      border: 1px solid var(--border-color);
      border-radius: 4px;
      overflow: hidden;
    }

    .core-btn {
      background: var(--bg-tertiary);
      border: none;
      color: var(--text-secondary);
      padding: 4px 10px;
      font-size: 0.75rem;
      font-weight: 600;
      cursor: pointer;
      transition: all 0.15s;
    }

    .core-btn.active {
      background: #0284c7;
      color: #fff;
    }

    .exec-actions {
      display: flex;
      gap: 6px;
    }

    .action-btn {
      padding: 4px 12px;
      border-radius: 4px;
      font-size: 0.75rem;
      font-weight: 600;
      border: 1px solid transparent;
      cursor: pointer;
      transition: all 0.1s;
      display: flex;
      align-items: center;
      gap: 4px;
    }

    .action-btn:disabled {
      opacity: 0.4;
      cursor: not-allowed;
    }

    .run-btn {
      background: #15803d;
      color: #fff;
      border-color: #16a34a;
    }
    .run-btn:not(:disabled):hover { background: #16a34a; }

    .pause-btn {
      background: #b45309;
      color: #fff;
      border-color: #d97706;
    }
    .pause-btn:not(:disabled):hover { background: #d97706; }

    .step-btn {
      background: #374151;
      color: #e5e7eb;
      border-color: #4b5563;
    }
    .step-btn:not(:disabled):hover { background: #4b5563; }

    .reset-btn {
      background: #374151;
      color: #e5e7eb;
      border-color: #4b5563;
    }
    .reset-btn:not(:disabled):hover { background: #4b5563; }

    .speed-control {
      display: flex;
      align-items: center;
      gap: 6px;
    }

    .speed-slider {
      width: 80px;
      accent-color: #0284c7;
      cursor: pointer;
    }

    .speed-val {
      font-size: 0.7rem;
      font-family: monospace;
      color: #94a3b8;
      min-width: 45px;
    }

    .status-indicator {
      margin-left: auto;
      display: flex;
      align-items: center;
      gap: 6px;
      font-size: 0.75rem;
      font-weight: 600;
      padding: 3px 8px;
      border-radius: 12px;
      background: #1e293b;
    }

    .status-dot {
      width: 8px;
      height: 8px;
      border-radius: 50%;
    }

    .status-running {
      color: #4ade80;
    }
    .status-running .status-dot {
      background: #4ade80;
      box-shadow: 0 0 6px #4ade80;
      animation: pulse 1s infinite;
    }

    .status-halted {
      color: #facc15;
    }
    .status-halted .status-dot {
      background: #facc15;
    }

    .status-stopped {
      color: #94a3b8;
    }
    .status-stopped .status-dot {
      background: #64748b;
    }

    .stop-banner {
      display: flex;
      gap: 16px;
      padding: 4px 12px;
      background: #23221a;
      border-top: 1px solid #423c1e;
      font-size: 0.75rem;
      font-family: monospace;
    }

    .stop-reason { color: #facc15; font-weight: bold; }
    .stop-pc { color: #38bdf8; }
    .stop-detail { color: #94a3b8; }
  `]
})
export class ExecutionControlsComponent {
  private emu = inject(EmulatorService);
  public Core = Core;

  public activeCore = this.emu.activeCore;
  public isConnected = computed(() => this.emu.connectionState() === 'connected');
  public isRunning = computed(() => this.emu.executionStatus() === 'running');
  public speed = this.emu.speedMilli;
  public lastStopInfo = this.emu.lastStop;

  public statusText = computed(() => {
    if (!this.isConnected()) return 'OFFLINE';
    switch (this.emu.executionStatus()) {
      case 'running': return 'RUNNING';
      case 'halted': return 'HALTED';
      default: return 'STOPPED';
    }
  });

  public statusClass = computed(() => {
    if (!this.isConnected()) return 'status-stopped';
    switch (this.emu.executionStatus()) {
      case 'running': return 'status-running';
      case 'halted': return 'status-halted';
      default: return 'status-stopped';
    }
  });

  public lastStopReason = computed(() => {
    const s = this.lastStopInfo();
    if (!s) return '';
    const reasons = ['Stepped', 'Breakpoint', 'Watchpoint', 'Halt Requested', 'Unit Break', 'Unit Watch', 'Count', 'Core Fault', 'Replay Failed'];
    return reasons[s.reason] || `Code ${s.reason}`;
  });

  public lastStopPc = computed(() => {
    const s = this.lastStopInfo();
    return s ? s.address.toString(16).padStart(8, '0') : '';
  });

  public lastStopDetail = computed(() => {
    const s = this.lastStopInfo();
    return s && s.detail !== 0 ? `0x${s.detail.toString(16)}` : null;
  });

  public selectCore(core: Core): void {
    void this.emu.switchCore(core);
  }

  public run(): void {
    void this.emu.run();
  }

  public pause(): void {
    void this.emu.pause();
  }

  public step(): void {
    void this.emu.step();
  }

  public reset(): void {
    void this.emu.reset();
  }

  public onSpeedChange(milli: number): void {
    void this.emu.setSpeed(milli);
  }
}
